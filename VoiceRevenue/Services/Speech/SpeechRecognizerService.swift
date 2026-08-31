import AVFoundation
import Foundation
import Network
import Speech

enum SpeechRecognitionMode: String, Equatable {
    case online
    case onDeviceFallback
}

enum SpeechRecognitionMethod: String, Equatable {
    case urlRequest
    case audioBufferRequest
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

private enum SpeechHotfixError: LocalizedError {
    case emptyTranscript
    case invalidAudioFile
    case unableToCreatePCMBuffer

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Apple Speech trả về transcript rỗng."
        case .invalidAudioFile:
            return "Không thể đọc file ghi âm để nhận diện giọng nói."
        case .unableToCreatePCMBuffer:
            return "Không thể tạo audio buffer để thử nhận diện lại."
        }
    }
}

private final class SpeechContinuationGate {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
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
    @Published private(set) var lastRecognitionMethod: SpeechRecognitionMethod = .urlRequest
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
    private var activeTask: SFSpeechRecognitionTask?

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

    /// Emergency iOS 15 recognition cascade.
    ///
    /// Normal attempt: URL request -> audio-buffer request -> on-device audio-buffer request.
    /// Retry attempt: audio-buffer request -> on-device audio-buffer request. The recorded file is reused.
    func transcribe(
        url: URL,
        initialContextualStrings: [String] = [],
        catalogProducts: [String] = [],
        preferBufferFirst: Bool = false
    ) async -> String? {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            return fail("Speech Recognition chưa được cấp quyền.")
        }
        guard let recognizer else {
            return fail("Không tạo được bộ nhận dạng tiếng Việt vi-VN.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return fail("File ghi âm không còn tồn tại để nhận diện.")
        }

        state = .recognizing
        lastError = nil
        lastPassOneTranscript = nil
        lastPassTwoTranscript = nil
        lastPassOneConfidence = nil
        lastPassTwoConfidence = nil

        let context = cappedContext(initialContextualStrings)
        let canTryOnline = recognizer.isAvailable
        let canTryOnDevice = supportsOnDevice

        var attempts: [(method: SpeechRecognitionMethod, mode: SpeechRecognitionMode, requireOnDevice: Bool)] = []

        if canTryOnline {
            if preferBufferFirst {
                attempts.append((.audioBufferRequest, .online, false))
            } else {
                attempts.append((.urlRequest, .online, false))
                attempts.append((.audioBufferRequest, .online, false))
            }
        }

        if canTryOnDevice {
            attempts.append((.audioBufferRequest, .onDeviceFallback, true))
        }

        diagnostics?.log(event: "speech.request", payload: [
            "networkAvailable": String(networkAvailable),
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(canTryOnDevice),
            "initialContextualCount": String(context.count),
            "catalogCount": String(catalogProducts.count),
            "preferBufferFirst": String(preferBufferFirst),
            "plannedAttempts": attempts.map { "\($0.mode.rawValue):\($0.method.rawValue)" }.joined(separator: ",")
        ])

        guard !attempts.isEmpty else {
            return fail("Nhận dạng giọng nói hiện không khả dụng và thiết bị không hỗ trợ vi-VN on-device.")
        }

        var latestError: Error?

        for attempt in attempts {
            lastRecognitionMode = attempt.mode
            lastRecognitionMethod = attempt.method

            diagnostics?.log(event: "speech.attempt", payload: [
                "recognitionMode": attempt.mode.rawValue,
                "method": attempt.method.rawValue,
                "requiresOnDevice": String(attempt.requireOnDevice),
                "contextualCount": String(context.count),
                "locale": recognizer.locale.identifier,
                "recognizerAvailable": String(recognizer.isAvailable),
                "onDeviceSupported": String(canTryOnDevice)
            ])

            do {
                let result: SpeechPassResult
                switch attempt.method {
                case .urlRequest:
                    result = try await recognizeURL(
                        url: url,
                        recognizer: recognizer,
                        requireOnDevice: attempt.requireOnDevice,
                        contextualStrings: context
                    )
                case .audioBufferRequest:
                    result = try await recognizeAudioBuffer(
                        url: url,
                        recognizer: recognizer,
                        requireOnDevice: attempt.requireOnDevice,
                        contextualStrings: context
                    )
                }

                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw SpeechHotfixError.emptyTranscript }

                lastPassOneTranscript = trimmed
                lastPassOneConfidence = result.averageConfidence
                state = .recognized(trimmed)

                diagnostics?.log(event: "speech.attempt.success", payload: [
                    "recognitionMode": attempt.mode.rawValue,
                    "method": attempt.method.rawValue,
                    "confidence": result.confidenceDescription,
                    "segmentConfidences": result.segmentConfidenceDescription,
                    "transcript": trimmed
                ])
                return trimmed
            } catch {
                latestError = error
                logAttemptFailure(
                    error,
                    method: attempt.method,
                    mode: attempt.mode,
                    requireOnDevice: attempt.requireOnDevice,
                    recognizer: recognizer
                )
            }
        }

        return fail(latestError?.localizedDescription ?? "Không nhận dạng được giọng nói.")
    }

    private func recognizeURL(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requireOnDevice: Bool,
        contextualStrings: [String]
    ) async throws -> SpeechPassResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        configure(request, requireOnDevice: requireOnDevice, contextualStrings: contextualStrings)
        return try await runRecognitionTask(recognizer: recognizer, request: request)
    }

    private func recognizeAudioBuffer(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requireOnDevice: Bool,
        contextualStrings: [String]
    ) async throws -> SpeechPassResult {
        let request = SFSpeechAudioBufferRecognitionRequest()
        configure(request, requireOnDevice: requireOnDevice, contextualStrings: contextualStrings)
        let gate = SpeechContinuationGate()

        activeTask?.cancel()
        activeTask = nil

        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechPassResult, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal, gate.claim() {
                        continuation.resume(returning: Self.passResult(from: result))
                    } else if let error, gate.claim() {
                        continuation.resume(throwing: error)
                    }
                }
                self.activeTask = task

                do {
                    // Recordings are short. Decode the existing file into PCM buffers once and
                    // feed them to a fresh Speech request. This avoids the iOS 15 URL-request path
                    // without asking the user to record again.
                    let file = try AVAudioFile(forReading: url)
                    guard file.length > 0, file.processingFormat.sampleRate > 0 else {
                        throw SpeechHotfixError.invalidAudioFile
                    }

                    while file.framePosition < file.length {
                        let remaining = file.length - file.framePosition
                        let frameCount = AVAudioFrameCount(min(Int64(4096), remaining))
                        guard frameCount > 0,
                              let buffer = AVAudioPCMBuffer(
                                pcmFormat: file.processingFormat,
                                frameCapacity: frameCount
                              ) else {
                            throw SpeechHotfixError.unableToCreatePCMBuffer
                        }

                        try file.read(into: buffer, frameCount: frameCount)
                        guard buffer.frameLength > 0 else { break }
                        request.append(buffer)
                    }

                    request.endAudio()
                } catch {
                    request.endAudio()
                    task.cancel()
                    if gate.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            activeTask = nil
            return result
        } catch {
            activeTask = nil
            throw error
        }
    }

    private func runRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest
    ) async throws -> SpeechPassResult {
        let gate = SpeechContinuationGate()
        activeTask?.cancel()
        activeTask = nil

        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechPassResult, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal, gate.claim() {
                        continuation.resume(returning: Self.passResult(from: result))
                    } else if let error, gate.claim() {
                        continuation.resume(throwing: error)
                    }
                }
                self.activeTask = task
            }
            activeTask = nil
            return result
        } catch {
            activeTask = nil
            throw error
        }
    }

    private func configure(
        _ request: SFSpeechRecognitionRequest,
        requireOnDevice: Bool,
        contextualStrings: [String]
    ) {
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = cappedContext(contextualStrings)
        request.requiresOnDeviceRecognition = requireOnDevice
    }

    private static func passResult(from result: SFSpeechRecognitionResult) -> SpeechPassResult {
        let segments = result.bestTranscription.segments
        let confidence: Double
        if segments.isEmpty {
            confidence = 0
        } else {
            confidence = segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
        }
        return SpeechPassResult(
            text: result.bestTranscription.formattedString,
            averageConfidence: confidence,
            segmentConfidences: segments.map(\.confidence)
        )
    }

    private func cappedContext(_ values: [String]) -> [String] {
        Array(
            VietnameseTextNormalizer
                .normalizedVocabulary(values)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(100)
        )
    }

    private func logAttemptFailure(
        _ error: Error,
        method: SpeechRecognitionMethod,
        mode: SpeechRecognitionMode,
        requireOnDevice: Bool,
        recognizer: SFSpeechRecognizer
    ) {
        let nsError = error as NSError
        diagnostics?.log(event: "speech.attempt.failed", payload: [
            "recognitionMode": mode.rawValue,
            "method": method.rawValue,
            "requiresOnDevice": String(requireOnDevice),
            "domain": nsError.domain,
            "code": String(nsError.code),
            "description": nsError.localizedDescription,
            "failureReason": nsError.localizedFailureReason ?? "",
            "locale": recognizer.locale.identifier,
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(supportsOnDevice)
        ])
    }

    private func fail(_ message: String) -> String? {
        lastError = message
        state = .failed(message)
        return nil
    }
}
