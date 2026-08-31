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
    static let parserVersion = "0.2.0"

    @Published private(set) var currentLogURL: URL?
    private let directory: URL
    private let fileManager = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()
    private var sessionID = UUID().uuidString

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
            "parserVersion": Self.parserVersion,
            "sessionID": sessionID
        ])
    }

    /// Critical diagnostic writes are intentionally synchronous (open/write/close). Event volume is
    /// tiny and durability matters more than micro-optimizing logging during this emergency patch.
    func log(event: String, payload: [String: String] = [:]) {
        guard let url = currentLogURL else { return }
        var object: [String: Any] = [
            "session_id": sessionID,
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

        do {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(lineData)
            try handle.close()
        } catch {
            // Do not recurse into logging. A later export will still surface prior durable events.
        }
    }

    /// Exports up to the last five persisted sessions into one JSONL file. This fixes the v0.1.3
    /// blind spot where exporting after an app relaunch returned only the new startup session.
    func exportURL() -> URL? {
        let files = sessionLogFilesNewestFirst()
        guard !files.isEmpty else { return nil }

        let selected = Array(files.prefix(5)).reversed()
        var aggregate = Data()
        for file in selected {
            if let data = try? Data(contentsOf: file) {
                aggregate.append(data)
                if let last = aggregate.last, last != 0x0A {
                    aggregate.append(0x0A)
                }
            }
        }
        guard !aggregate.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let export = fileManager.temporaryDirectory
            .appendingPathComponent("VoiceRevenue-Diagnostic-\(formatter.string(from: Date())).jsonl")
        do {
            try aggregate.write(to: export, options: .atomic)
            return export
        } catch {
            return nil
        }
    }

    func clearLogs() {
        for file in sessionLogFilesNewestFirst() {
            try? fileManager.removeItem(at: file)
        }
        sessionID = UUID().uuidString
        currentLogURL = makeSessionURL()
        if let url = currentLogURL {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        log(event: "diagnostics.cleared")
    }

    private func makeSessionURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let shortID = String(sessionID.prefix(8))
        return directory.appendingPathComponent(
            "VoiceRevenue-Session-\(formatter.string(from: Date()))-\(shortID).jsonl"
        )
    }

    private func sessionLogFilesNewestFirst() -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.lastPathComponent.hasPrefix("VoiceRevenue-Session-") && $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    private func pruneLogs() {
        let files = sessionLogFilesNewestFirst()
        var totalBytes = 0
        for (index, file) in files.enumerated() {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += size
            if index >= 5 || totalBytes > 2_000_000 {
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
    @Published var speechFailureMessage: String?

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
        Task { await speech.refreshModelState() }
    }

    func startRecording() async {
        speechFailureMessage = nil
        alertMessage = nil
        transcript = ""
        candidates = []
        speech.resetForNewRecording()

        await recorder.start()
        switch recorder.state {
        case .recording:
            diagnostics.log(event: "recording.started", payload: [
                "speechEngine": SpeechRecognizerService.engineName,
                "speechModel": SpeechRecognizerService.modelName,
                "mode": "offline_record_then_transcribe"
            ])
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
        guard case .recorded(let url) = recorder.state else {
            speechFailureMessage = "Không lấy được file ghi âm sau khi dừng."
            return
        }

        var audioPayload = [
            "file": url.lastPathComponent,
            "extension": url.pathExtension.lowercased(),
            "fileExists": String(FileManager.default.fileExists(atPath: url.path))
        ]
        if let metadata = recorder.metadata(for: url) {
            for (key, value) in metadata.logPayload { audioPayload[key] = value }
        }
        diagnostics.log(event: "recording.stopped", payload: audioPayload)
        diagnostics.log(event: "recording.audio.format", payload: audioPayload)

        await recognizeRecording(url: url, allowRemoteReinforcement: true)
        flow = .transcript
    }

    func retryTranscription() async {
        guard !isProcessingRecording else { return }
        guard let url = recorder.lastRecordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            speechFailureMessage = "Không còn file ghi âm để thử lại."
            return
        }

        isProcessingRecording = true
        defer { isProcessingRecording = false }
        diagnostics.log(event: "speech.retry.requested", payload: [
            "file": url.lastPathComponent,
            "strategy": "localOpenSourceThenOptionalSelfHosted"
        ])
        await recognizeRecording(url: url, allowRemoteReinforcement: true)
        flow = .transcript
    }

    /// Diagnostics-only local speech test. It never parses or creates accounting candidates.
    func testLastRecordingSpeech() async {
        guard !isProcessingRecording else { return }
        guard let url = recorder.lastRecordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "Chưa có file ghi âm gần nhất để test."
            return
        }

        isProcessingRecording = true
        defer { isProcessingRecording = false }
        diagnostics.log(event: "speech.diagnostic_test.requested", payload: [
            "file": url.lastPathComponent,
            "engine": SpeechRecognizerService.engineName
        ])

        let text = await speech.transcribeLocalOnly(url: url, catalogProducts: vocabulary.allProducts)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alertMessage = trimmed.isEmpty
            ? (speech.lastError ?? "Test nhận diện offline thất bại.")
            : "Offline STT OK: \(trimmed)"
    }

    func useAlternateTranscript() {
        guard let replacement = speech.activateAlternate(currentText: transcript) else { return }
        transcript = replacement
        speechFailureMessage = nil
    }

    private func recognizeRecording(url: URL, allowRemoteReinforcement: Bool) async {
        let text = await speech.transcribe(
            url: url,
            catalogProducts: vocabulary.allProducts,
            allowRemoteReinforcement: allowRemoteReinforcement
        )

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            transcript = ""
            candidates = []
            speechFailureMessage = speech.lastError ?? "Không thể nhận diện giọng nói bằng model offline."
            diagnostics.log(event: "speech.failed", payload: [
                "recognitionMode": speech.lastRecognitionMode.rawValue,
                "method": speech.lastRecognitionMethod.rawValue,
                "error": speech.lastError ?? "unknown",
                "file": url.lastPathComponent
            ])
            return
        }

        acceptRecognizedText(trimmed, url: url, source: speech.lastRecognitionMethod.rawValue)
    }

    private func acceptRecognizedText(_ text: String, url: URL, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcript = ""
            candidates = []
            speechFailureMessage = "Không thể nhận diện giọng nói."
            diagnostics.log(event: "speech.result.rejected_empty", payload: ["source": source])
            return
        }

        transcript = trimmed
        speechFailureMessage = nil
        diagnostics.log(event: "speech.result", payload: [
            "recognitionMode": speech.lastRecognitionMode.rawValue,
            "method": speech.lastRecognitionMethod.rawValue,
            "source": source,
            "engine": SpeechRecognizerService.engineName,
            "model": SpeechRecognizerService.modelName,
            "rawTranscript": trimmed,
            "normalizedTranscript": VietnameseTextNormalizer.normalize(trimmed),
            "catalogCount": String(vocabulary.catalogCount),
            "file": url.lastPathComponent
        ])
    }

    func cancelRecording() {
        recorder.cancel()
        diagnostics.log(event: "recording.cancelled")
        flow = .home
    }

    func parseTranscript() {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            candidates = []
            diagnostics.log(event: "parser.skipped.empty_transcript")
            alertMessage = "Chưa có transcript để phân tích. Hãy thử nhận diện lại hoặc nhập nội dung thủ công."
            return
        }

        transcript = cleaned
        speechFailureMessage = nil
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

    func updateTransaction(
        _ item: TransactionEntity,
        amountVND: Int64,
        customerName: String?,
        product: String?,
        paymentMethod: PaymentMethod,
        paymentAt: Date?,
        notes: String?
    ) throws {
        try repository.update(
            item,
            amountVND: amountVND,
            customerName: customerName,
            product: product,
            paymentMethod: paymentMethod,
            paymentAt: paymentAt,
            notes: notes,
            markForSync: sync.isConfigured
        )
        diagnostics.log(event: "history.transaction.updated", payload: [
            "transactionID": item.transactionID.uuidString,
            "amountVND": String(amountVND),
            "syncStatus": item.syncStatus
        ])
        if sync.isConfigured {
            Task { await syncPendingIfConfigured() }
        }
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
