import CoreData
import Foundation
import UIKit

@MainActor
final class ProductVocabularyStore: ObservableObject {
    private enum Keys {
        static let vocabulary = "productVocabulary.v0.1.1"
        static let corrections = "productCorrections.v0.1.1"
    }

    private static let starterVocabulary = [
        "dập ghim",
        "dây điện",
        "bấm móng tay",
        "ốc vít",
        "biển neon"
    ]

    @Published var editableText: String {
        didSet { UserDefaults.standard.set(editableText, forKey: Keys.vocabulary) }
    }

    @Published private var learnedCorrections: [String: String]

    init() {
        if let stored = UserDefaults.standard.string(forKey: Keys.vocabulary), !stored.isEmpty {
            editableText = stored
        } else {
            editableText = Self.starterVocabulary.joined(separator: "\n")
        }
        learnedCorrections = UserDefaults.standard.dictionary(forKey: Keys.corrections) as? [String: String] ?? [:]
    }

    var products: [String] {
        let values = editableText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(VietnameseTextNormalizer.normalizedVocabulary(values).prefix(100))
    }

    var corrections: [String: String] { learnedCorrections }

    func learnCorrection(from observed: String, to canonical: String) {
        let observedKey = VietnameseTextNormalizer.normalize(observed)
        let canonicalValue = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observedKey.isEmpty, !canonicalValue.isEmpty,
              observedKey != VietnameseTextNormalizer.normalize(canonicalValue) else { return }
        learnedCorrections[observedKey] = canonicalValue
        UserDefaults.standard.set(learnedCorrections, forKey: Keys.corrections)
    }

    func clearCorrections() {
        learnedCorrections.removeAll()
        UserDefaults.standard.removeObject(forKey: Keys.corrections)
    }

    var learnedCorrectionCount: Int { learnedCorrections.count }
}

@MainActor
final class DiagnosticLogger: ObservableObject {
    static let parserVersion = "0.1.1"

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
        diagnostics.log(event: "recording.stopped", payload: ["file": url.lastPathComponent])

        if let text = await speech.transcribe(url: url, contextualStrings: vocabulary.products) {
            transcript = text
            diagnostics.log(event: "speech.result", payload: [
                "recognitionMode": speech.lastRecognitionMode.rawValue,
                "rawTranscript": text,
                "normalizedTranscript": VietnameseTextNormalizer.normalize(text),
                "contextualVocabularyCount": String(vocabulary.products.count),
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
            vocabulary: vocabulary.products,
            corrections: vocabulary.corrections
        )
        if candidates.isEmpty {
            candidates = [CandidateTransaction(needsReview: true, sourceText: transcript)]
        }
        for candidate in candidates {
            diagnostics.log(event: "parser.product_match", payload: [
                "sourceText": candidate.sourceText,
                "observedProduct": candidate.originalProductText ?? "nil",
                "finalProduct": candidate.product ?? "nil",
                "matchKind": candidate.productMatchKind?.rawValue ?? "none",
                "matchScore": candidate.productMatchScore.map { String(format: "%.3f", $0) } ?? "nil",
                "needsReview": String(candidate.needsReview)
            ])
        }

        diagnostics.log(event: "parser.result", payload: [
            "rawTranscript": transcript,
            "normalizedTranscript": VietnameseTextNormalizer.normalize(transcript),
            "candidateCount": String(candidates.count),
            "candidates": candidates.map { candidate in
                [
                    candidate.customerName ?? "nil",
                    candidate.product ?? "nil",
                    candidate.amountVND.map(String.init) ?? "nil",
                    candidate.productMatchKind?.rawValue ?? "none",
                    candidate.productMatchScore.map { String(format: "%.3f", $0) } ?? "nil",
                    candidate.needsReview ? "review" : "ok"
                ].joined(separator: " | ")
            }.joined(separator: " || ")
        ])
        flow = .review
    }

    func confirmCandidates() {
        do {
            for candidate in candidates {
                if let original = candidate.originalProductText,
                   let finalProduct = candidate.product,
                   VietnameseTextNormalizer.normalize(original) != VietnameseTextNormalizer.normalize(finalProduct) {
                    vocabulary.learnCorrection(from: original, to: finalProduct)
                    diagnostics.log(event: "review.product_correction", payload: [
                        "from": original,
                        "to": finalProduct
                    ])
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
}
