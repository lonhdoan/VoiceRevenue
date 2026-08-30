import CoreData
import Foundation
import UIKit

private struct LearnedCorrectionRecord: Codable, Equatable {
    let sourceNormalized: String
    var canonicalProduct: String
    var confirmations: Int
    var lastConfirmed: Date
}

@MainActor
final class ProductVocabularyStore: ObservableObject {
    private enum Keys {
        static let customVocabulary = "productVocabulary.v0.1.1"
        static let legacyCorrections = "productCorrections.v0.1.1"
        static let correctionRecords = "productCorrections.v0.1.2"
        static let recentProducts = "recentConfirmedProducts.v0.1.2"
    }

    private static let starterVocabulary = [
        "dập ghim",
        "dây điện",
        "bấm móng tay",
        "ốc vít",
        "biển neon"
    ]

    @Published var editableText: String {
        didSet { UserDefaults.standard.set(editableText, forKey: Keys.customVocabulary) }
    }

    @Published private var learnedRecords: [String: LearnedCorrectionRecord]
    @Published private var recentConfirmedProducts: [String]

    let catalog: ProductCatalogFile?

    init() {
        catalog = ProductCatalogLoader.loadBundled()

        if let stored = UserDefaults.standard.string(forKey: Keys.customVocabulary), !stored.isEmpty {
            editableText = stored
        } else {
            editableText = Self.starterVocabulary.joined(separator: "\n")
        }

        if let data = UserDefaults.standard.data(forKey: Keys.correctionRecords),
           let decoded = try? JSONDecoder().decode([String: LearnedCorrectionRecord].self, from: data) {
            learnedRecords = decoded
        } else {
            let legacy = UserDefaults.standard.dictionary(forKey: Keys.legacyCorrections) as? [String: String] ?? [:]
            learnedRecords = legacy.reduce(into: [:]) { partial, pair in
                let source = VietnameseTextNormalizer.normalize(pair.key)
                let canonical = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty, !canonical.isEmpty else { return }
                partial[source] = LearnedCorrectionRecord(
                    sourceNormalized: source,
                    canonicalProduct: canonical,
                    confirmations: 1,
                    lastConfirmed: Date()
                )
            }
        }

        recentConfirmedProducts = UserDefaults.standard.stringArray(forKey: Keys.recentProducts) ?? []
    }

    var catalogCount: Int { catalog?.productCount ?? 0 }
    var catalogSourceFile: String { catalog?.sourceFile ?? "Không có catalog" }

    var customProducts: [String] {
        VietnameseTextNormalizer.normalizedVocabulary(
            editableText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    var allProducts: [String] {
        // Preserve normalized collisions from the real catalog. Two distinct Vietnamese names
        // can become identical after accent-insensitive normalization; the matcher knows how to
        // keep those ambiguous instead of silently dropping one.
        let values = customProducts + (catalog?.products.map(\.name) ?? [])
        var seen = Set<String>()
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.folding(options: [.caseInsensitive], locale: Locale(identifier: "vi_VN"))
            return !trimmed.isEmpty && seen.insert(key).inserted
        }
    }

    var initialContextualStrings: [String] {
        let learned = learnedRecords.values
            .sorted { $0.lastConfirmed > $1.lastConfirmed }
            .map(\.canonicalProduct)
        let values = learned + recentConfirmedProducts + customProducts
        return Array(VietnameseTextNormalizer.normalizedVocabulary(values).prefix(100))
    }

    var corrections: [String: String] {
        learnedRecords.reduce(into: [:]) { partial, pair in
            partial[pair.key] = pair.value.canonicalProduct
        }
    }

    func learnCorrection(from observed: String, to canonical: String) {
        let observedKey = VietnameseTextNormalizer.normalize(observed)
        let canonicalValue = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observedKey.isEmpty, !canonicalValue.isEmpty,
              observedKey != VietnameseTextNormalizer.normalize(canonicalValue) else { return }

        if var existing = learnedRecords[observedKey] {
            existing.canonicalProduct = canonicalValue
            existing.confirmations += 1
            existing.lastConfirmed = Date()
            learnedRecords[observedKey] = existing
        } else {
            learnedRecords[observedKey] = LearnedCorrectionRecord(
                sourceNormalized: observedKey,
                canonicalProduct: canonicalValue,
                confirmations: 1,
                lastConfirmed: Date()
            )
        }
        persistCorrections()
    }

    func recordConfirmedProducts(_ productText: String) {
        let values = productText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var ordered = values + recentConfirmedProducts
        var seen = Set<String>()
        ordered = ordered.filter { value in
            let key = VietnameseTextNormalizer.normalize(value)
            return !key.isEmpty && seen.insert(key).inserted
        }
        recentConfirmedProducts = Array(ordered.prefix(50))
        UserDefaults.standard.set(recentConfirmedProducts, forKey: Keys.recentProducts)
    }

    func clearCorrections() {
        learnedRecords.removeAll()
        UserDefaults.standard.removeObject(forKey: Keys.correctionRecords)
        UserDefaults.standard.removeObject(forKey: Keys.legacyCorrections)
    }

    var learnedCorrectionCount: Int { learnedRecords.count }

    private func persistCorrections() {
        if let data = try? JSONEncoder().encode(learnedRecords) {
            UserDefaults.standard.set(data, forKey: Keys.correctionRecords)
        }
    }
}

@MainActor
final class DiagnosticLogger: ObservableObject {
    static let parserVersion = "0.1.2"

    @Published private(set) var currentLogURL: URL?
    private let directory: URL
    private let fileManager = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("VoiceRevenue/Diagnostics", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        currentLogURL = makeSessionURL()
        if let url = currentLogURL, !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        pruneLogs()
        log(event: "app.session.started", payload: [
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "iOS": UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "parserVersion": Self.parserVersion
        ])
    }

    func log(event: String, payload: [String: String] = [:]) {
        guard let url = currentLogURL else { return }
        var object: [String: Any] = [
            "timestamp": isoFormatter.string(from: Date()),
            "event": event,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "ios_version": UIDevice.current.systemVersion,
            "device_model": UIDevice.current.model,
            "parser_version": Self.parserVersion,
            "payload": payload
        ]
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            object["build"] = build
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            try? handle.close()
        }
    }

    func exportURL() -> URL? { currentLogURL }

    func clearLogs() {
        if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? fileManager.removeItem(at: file) }
        }
        currentLogURL = makeSessionURL()
        if let url = currentLogURL {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        log(event: "diagnostics.cleared")
    }

    private func makeSessionURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return directory.appendingPathComponent("VoiceRevenue-Diagnostic-\(formatter.string(from: Date())).jsonl")
    }

    private func pruneLogs() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }

        var totalBytes = 0
        for (index, file) in sorted.enumerated() {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            totalBytes += values?.fileSize ?? 0
            if index >= 29 || totalBytes > 1_000_000 {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    enum Flow { case home, recording, transcript, review }

    @Published var flow: Flow = .home
    @Published var transcript: String = ""
    @Published var candidates: [CandidateTransaction] = []
    @Published var alertMessage: String?
    @Published var isProcessingRecording = false

    let recorder = AudioRecorder()
    let speech = SpeechRecognizerService()
    let repository: TransactionRepository
    let sync = GoogleSheetsSyncService()
    let vocabulary = ProductVocabularyStore()
    let diagnostics = DiagnosticLogger()
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        self.repository = TransactionRepository(context: context)
        speech.diagnostics = diagnostics
        sync.diagnostics = diagnostics
        diagnostics.log(event: "catalog.loaded", payload: [
            "count": String(vocabulary.catalogCount),
            "sourceFile": vocabulary.catalogSourceFile,
            "customVocabularyCount": String(vocabulary.customProducts.count)
        ])
    }

    func startRecording() async {
        await recorder.start()
        switch recorder.state {
        case .recording:
            diagnostics.log(event: "recording.started")
            flow = .recording
        case .failed(let message):
            diagnostics.log(event: "recording.failed", payload: ["error": message])
            alertMessage = message
        default:
            diagnostics.log(event: "recording.not_started")
        }
    }

    func stopAndTranscribe() async {
        guard !isProcessingRecording else { return }
        isProcessingRecording = true
        defer { isProcessingRecording = false }

        recorder.stop()
        guard case .recorded(let url) = recorder.state else { return }

        var audioPayload = ["file": url.lastPathComponent]
        if let metadata = recorder.metadata(for: url) {
            for (key, value) in metadata.logPayload { audioPayload[key] = value }
        }
        diagnostics.log(event: "recording.stopped", payload: audioPayload)

        if let text = await speech.transcribe(
            url: url,
            initialContextualStrings: vocabulary.initialContextualStrings,
            catalogProducts: vocabulary.allProducts
        ) {
            transcript = text
            diagnostics.log(event: "speech.result", payload: [
                "recognitionMode": speech.lastRecognitionMode.rawValue,
                "rawTranscript": text,
                "normalizedTranscript": VietnameseTextNormalizer.normalize(text),
                "initialContextualCount": String(vocabulary.initialContextualStrings.count),
                "catalogCount": String(vocabulary.catalogCount),
                "onDeviceSupported": String(speech.supportsOnDevice)
            ])
        } else {
            transcript = ""
            diagnostics.log(event: "speech.failed", payload: [
                "recognitionMode": speech.lastRecognitionMode.rawValue,
                "error": speech.lastError ?? "unknown"
            ])
            alertMessage = "Không nhận dạng được giọng nói. Bạn có thể nhập transcript thủ công."
        }
        flow = .transcript
    }

    func cancelRecording() {
        recorder.cancel()
        diagnostics.log(event: "recording.cancelled")
        flow = .home
    }

    func parseTranscript() {
        let segments = TransactionSegmenter.segments(from: transcript)
        diagnostics.log(event: "parser.segmented", payload: [
            "segmentCount": String(segments.count),
            "segments": segments.joined(separator: " || ")
        ])

        candidates = TransactionParser.parse(
            transcript,
            vocabulary: vocabulary.allProducts,
            corrections: vocabulary.corrections
        )
        if candidates.isEmpty {
            candidates = [CandidateTransaction(needsReview: true, sourceText: transcript)]
        }

        for candidate in candidates {
            let evidence = candidate.productMatches.map { item in
                let scoreText = item.score.map { String(format: "%.3f", $0) } ?? "nil"
                return [
                    "source=\(item.sourcePhrase)",
                    "canonical=\(item.canonicalProduct)",
                    "kind=\(item.matchKind.rawValue)",
                    "score=\(scoreText)",
                    "tokenStart=\(item.tokenStart)",
                    "tokenCount=\(item.tokenCount)",
                    "review=\(item.requiresReview)"
                ].joined(separator: ",")
            }.joined(separator: " || ")

            let rejected = candidate.rejectedProductCandidates.map { item in
                [
                    "source=\(item.sourcePhrase)",
                    "candidate=\(item.canonicalProduct)",
                    "score=\(String(format: "%.3f", item.score))",
                    "second=\(String(format: "%.3f", item.secondBestScore))",
                    "tokenStart=\(item.tokenStart)",
                    "tokenCount=\(item.tokenCount)",
                    "reason=\(item.reason)"
                ].joined(separator: ",")
            }.joined(separator: " || ")

            diagnostics.log(event: "parser.product_match", payload: [
                "sourceText": candidate.sourceText,
                "observedProduct": candidate.originalProductText ?? "nil",
                "finalProduct": candidate.product ?? "nil",
                "matchKind": candidate.productMatchKind?.rawValue ?? "none",
                "matchScore": candidate.productMatchScore.map { String(format: "%.3f", $0) } ?? "nil",
                "needsReview": String(candidate.needsReview),
                "evidence": evidence,
                "rejectedCandidates": rejected
            ])
        }

        diagnostics.log(event: "parser.result", payload: [
            "rawTranscript": transcript,
            "normalizedTranscript": VietnameseTextNormalizer.normalize(transcript),
            "candidateCount": String(candidates.count)
        ])
        flow = .review
    }

    func confirmCandidates() {
        do {
            for candidate in candidates {
                learnSafeCorrections(from: candidate)
                if let product = candidate.product {
                    vocabulary.recordConfirmedProducts(product)
                }
                try repository.save(candidate, transcript: transcript)
            }
            diagnostics.log(event: "transactions.confirmed", payload: ["count": String(candidates.count)])
            candidates = []
            transcript = ""
            flow = .home
            Task { await syncPendingIfConfigured() }
        } catch {
            diagnostics.log(event: "transactions.save_error", payload: ["error": error.localizedDescription])
            alertMessage = error.localizedDescription
        }
    }

    func syncPendingIfConfigured() async {
        guard sync.isConfigured else { return }
        repository.reload()
        for item in repository.transactions where item.syncStatus != SyncStatus.synced.rawValue {
            if item.syncStatus == SyncStatus.notConfigured.rawValue {
                item.syncStatus = SyncStatus.pending.rawValue
                try? context.save()
            }
            _ = await sync.sync(item, context: context)
        }
        repository.reload()
    }

    private func learnSafeCorrections(from candidate: CandidateTransaction) {
        guard let finalProduct = candidate.product else { return }
        let finalLines = finalProduct
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for evidence in candidate.productMatches where evidence.matchKind == .fuzzySuggestion {
            guard normalizedPhraseExists(evidence.sourcePhrase, in: candidate.sourceText) else { continue }
            let canonicalMatch = finalLines.first {
                VietnameseTextNormalizer.normalize($0) == VietnameseTextNormalizer.normalize(evidence.canonicalProduct)
            }
            if let canonicalMatch {
                vocabulary.learnCorrection(from: evidence.sourcePhrase, to: canonicalMatch)
                diagnostics.log(event: "review.product_correction", payload: [
                    "from": evidence.sourcePhrase,
                    "to": canonicalMatch,
                    "reason": "confirmed_fuzzy_suggestion"
                ])
            } else if candidate.productMatches.count == 1, finalLines.count == 1, let edited = finalLines.first {
                vocabulary.learnCorrection(from: evidence.sourcePhrase, to: edited)
                diagnostics.log(event: "review.product_correction", payload: [
                    "from": evidence.sourcePhrase,
                    "to": edited,
                    "reason": "manual_edit"
                ])
            }
        }

        if candidate.productMatches.count == 1,
           let only = candidate.productMatches.first,
           only.matchKind == .raw,
           finalLines.count == 1,
           let edited = finalLines.first,
           VietnameseTextNormalizer.normalize(edited) != VietnameseTextNormalizer.normalize(only.sourcePhrase),
           normalizedPhraseExists(only.sourcePhrase, in: candidate.sourceText) {
            vocabulary.learnCorrection(from: only.sourcePhrase, to: edited)
            diagnostics.log(event: "review.product_correction", payload: [
                "from": only.sourcePhrase,
                "to": edited,
                "reason": "manual_raw_edit"
            ])
        }
    }

    private func normalizedPhraseExists(_ phrase: String, in source: String) -> Bool {
        let normalizedPhrase = VietnameseTextNormalizer.normalize(phrase)
        let normalizedSource = VietnameseTextNormalizer.normalize(source)
        return !normalizedPhrase.isEmpty && normalizedSource.range(of: normalizedPhrase) != nil
    }
}
