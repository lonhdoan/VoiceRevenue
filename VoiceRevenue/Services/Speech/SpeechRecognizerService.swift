import Foundation
import Network
import Speech

enum SpeechRecognitionMode: String, Equatable {
    case online
    case onDeviceFallback
}

enum SpeechRecognitionPlanner {
    static func orderedModes(
        networkAvailable: Bool,
        recognizerAvailable: Bool,
        supportsOnDevice: Bool
    ) -> [SpeechRecognitionMode] {
        if networkAvailable && recognizerAvailable {
            return supportsOnDevice ? [.online, .onDeviceFallback] : [.online]
        }
        if supportsOnDevice {
            return [.onDeviceFallback]
        }
        if recognizerAvailable {
            return [.online]
        }
        return []
    }
}

struct SpeechPassResult: Equatable {
    let text: String
    let averageConfidence: Double
    let segmentConfidences: [Float]

    var segmentCount: Int { segmentConfidences.count }

    var confidenceDescription: String {
        String(format: "%.3f", averageConfidence)
    }

    var segmentConfidenceDescription: String {
        segmentConfidences.map { String(format: "%.3f", $0) }.joined(separator: ",")
    }
}

@MainActor
final class SpeechRecognizerService: ObservableObject {
    enum State: Equatable {
        case idle
        case recognizing
        case recognized(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastRecognitionMode: SpeechRecognitionMode = .online
    @Published private(set) var lastError: String?
    @Published private(set) var lastPassOneTranscript: String?
    @Published private(set) var lastPassTwoTranscript: String?
    @Published private(set) var lastPassOneConfidence: Double?
    @Published private(set) var lastPassTwoConfidence: Double?

    weak var diagnostics: DiagnosticLogger?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "VoiceRevenue.NetworkMonitor")
    private var networkAvailable = true

    init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkAvailable = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    deinit {
        networkMonitor.cancel()
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribe(
        url: URL,
        initialContextualStrings: [String] = [],
        catalogProducts: [String] = []
    ) async -> String? {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            return fail("Speech Recognition chưa được cấp quyền.")
        }
        guard let recognizer else {
            return fail("Không tạo được bộ nhận dạng tiếng Việt vi-VN.")
        }

        state = .recognizing
        lastError = nil
        lastPassOneTranscript = nil
        lastPassTwoTranscript = nil
        lastPassOneConfidence = nil
        lastPassTwoConfidence = nil

        let initialContext = cappedContext(initialContextualStrings)
        let modes = SpeechRecognitionPlanner.orderedModes(
            networkAvailable: networkAvailable,
            recognizerAvailable: recognizer.isAvailable,
            supportsOnDevice: supportsOnDevice
        )

        diagnostics?.log(event: "speech.request", payload: [
            "networkAvailable": String(networkAvailable),
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(supportsOnDevice),
            "initialContextualCount": String(initialContext.count),
            "plannedModes": modes.map(\.rawValue).joined(separator: ",")
        ])

        guard !modes.isEmpty else {
            return fail("Nhận dạng giọng nói hiện không khả dụng và thiết bị không hỗ trợ vi-VN on-device.")
        }

        var latestError: Error?
        for mode in modes {
            lastRecognitionMode = mode
            let requireOnDevice = mode == .onDeviceFallback
            diagnostics?.log(event: "speech.attempt", payload: [
                "recognitionMode": mode.rawValue,
                "requiresOnDevice": String(requireOnDevice)
            ])

            do {
                if mode == .online {
                    let result = try await recognizeOnlineTwoPass(
                        url: url,
                        recognizer: recognizer,
                        initialContext: initialContext,
                        catalogProducts: catalogProducts
                    )
                    state = .recognized(result.text)
                    diagnostics?.log(event: "speech.attempt.success", payload: [
                        "recognitionMode": mode.rawValue,
                        "confidence": result.confidenceDescription
                    ])
                    return result.text
                }

                let result = try await recognize(
                    url: url,
                    recognizer: recognizer,
                    requireOnDevice: true,
                    contextualStrings: initialContext
                )
                state = .recognized(result.text)
                diagnostics?.log(event: "speech.attempt.success", payload: [
                    "recognitionMode": mode.rawValue,
                    "confidence": result.confidenceDescription
                ])
                return result.text
            } catch {
                latestError = error
                diagnostics?.log(event: "speech.attempt.failed", payload: [
                    "recognitionMode": mode.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }

        return fail(latestError?.localizedDescription ?? "Không nhận dạng được giọng nói.")
    }

    private func recognizeOnlineTwoPass(
        url: URL,
        recognizer: SFSpeechRecognizer,
        initialContext: [String],
        catalogProducts: [String]
    ) async throws -> SpeechPassResult {
        let first = try await recognize(
            url: url,
            recognizer: recognizer,
            requireOnDevice: false,
            contextualStrings: initialContext
        )
        lastPassOneTranscript = first.text
        lastPassOneConfidence = first.averageConfidence

        diagnostics?.log(event: "speech.pass1.result", payload: [
            "transcript": first.text,
            "confidence": first.confidenceDescription,
            "segments": String(first.segmentCount),
            "segmentConfidences": first.segmentConfidenceDescription,
            "contextualStrings": initialContext.joined(separator: " | ")
        ])

        let shortlist = ProductCatalogMatcher.contextualShortlist(
            from: first.text,
            vocabulary: catalogProducts,
            priority: initialContext,
            limit: 100
        )
        let newShortlistKeys = Set(shortlist.map(VietnameseTextNormalizer.normalize))
            .subtracting(Set(initialContext.map(VietnameseTextNormalizer.normalize)))

        diagnostics?.log(event: "speech.catalog.shortlist", payload: [
            "count": String(shortlist.count),
            "newCandidateCount": String(newShortlistKeys.count),
            "items": shortlist.joined(separator: " | ")
        ])

        // A second request is only useful when pass 1 found evidence-backed catalog candidates
        // that were not already present in the initial context.
        guard !newShortlistKeys.isEmpty else { return first }

        do {
            let second = try await recognize(
                url: url,
                recognizer: recognizer,
                requireOnDevice: false,
                contextualStrings: shortlist
            )
            lastPassTwoTranscript = second.text
            lastPassTwoConfidence = second.averageConfidence

            let firstExact = ProductCatalogMatcher.exactEvidenceCount(in: first.text, vocabulary: catalogProducts)
            let secondExact = ProductCatalogMatcher.exactEvidenceCount(in: second.text, vocabulary: catalogProducts)
            let chooseSecond = shouldChooseSecondPass(first: first, second: second)

            diagnostics?.log(event: "speech.pass2.result", payload: [
                "transcript": second.text,
                "confidence": second.confidenceDescription,
                "segments": String(second.segmentCount),
                "segmentConfidences": second.segmentConfidenceDescription,
                "exactCatalogEvidence": String(secondExact),
                "pass1ExactCatalogEvidence": String(firstExact),
                "selectionRule": "confidence_only_no_catalog_reinforcement",
                "selected": String(chooseSecond)
            ])
            return chooseSecond ? second : first
        } catch {
            // Pass 1 is already a valid online recognition result. A pass-2 failure should not
            // discard it or force the user to re-record.
            diagnostics?.log(event: "speech.pass2.failed", payload: ["error": error.localizedDescription])
            return first
        }
    }

    private func shouldChooseSecondPass(
        first: SpeechPassResult,
        second: SpeechPassResult
    ) -> Bool {
        // Catalog hints are allowed to help recognition, but catalog matches are NOT allowed to
        // decide the winner. That would self-reinforce a hallucinated product. Pass 2 wins only
        // when Apple's own segment confidence materially improves.
        guard VietnameseTextNormalizer.normalize(first.text) != VietnameseTextNormalizer.normalize(second.text) else {
            return false
        }
        return second.averageConfidence >= first.averageConfidence + 0.015
    }

    private func recognize(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requireOnDevice: Bool,
        contextualStrings: [String]
    ) async throws -> SpeechPassResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = cappedContext(contextualStrings)
        request.requiresOnDeviceRecognition = requireOnDevice

        return try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !didFinish else { return }
                if let result, result.isFinal {
                    didFinish = true
                    let segments = result.bestTranscription.segments
                    let confidence: Double
                    if segments.isEmpty {
                        confidence = 0
                    } else {
                        confidence = segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
                    }
                    continuation.resume(
                        returning: SpeechPassResult(
                            text: result.bestTranscription.formattedString,
                            averageConfidence: confidence,
                            segmentConfidences: segments.map(\.confidence)
                        )
                    )
                } else if let error {
                    didFinish = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cappedContext(_ values: [String]) -> [String] {
        Array(VietnameseTextNormalizer.normalizedVocabulary(values).prefix(100))
    }

    private func fail(_ message: String) -> String? {
        lastError = message
        state = .failed(message)
        return nil
    }
}
