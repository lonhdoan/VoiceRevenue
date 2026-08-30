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
        // NWPathMonitor can briefly be stale during app launch. If Apple's recognizer itself
        // reports available, allow one online-capable attempt rather than failing immediately.
        if recognizerAvailable {
            return [.online]
        }
        return []
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
        if #available(iOS 13.0, *) {
            return recognizer?.supportsOnDeviceRecognition ?? false
        }
        return false
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribe(url: URL, contextualStrings: [String] = []) async -> String? {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            return fail("Speech Recognition chưa được cấp quyền.")
        }
        guard let recognizer else {
            return fail("Không tạo được bộ nhận dạng tiếng Việt vi-VN.")
        }

        state = .recognizing
        lastError = nil
        let context = Array(VietnameseTextNormalizer.normalizedVocabulary(contextualStrings).prefix(100))
        let modes = SpeechRecognitionPlanner.orderedModes(
            networkAvailable: networkAvailable,
            recognizerAvailable: recognizer.isAvailable,
            supportsOnDevice: supportsOnDevice
        )

        diagnostics?.log(event: "speech.request", payload: [
            "networkAvailable": String(networkAvailable),
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(supportsOnDevice),
            "contextualVocabularyCount": String(context.count),
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
                let text = try await recognize(
                    url: url,
                    recognizer: recognizer,
                    requireOnDevice: requireOnDevice,
                    contextualStrings: context
                )
                state = .recognized(text)
                diagnostics?.log(event: "speech.attempt.success", payload: ["recognitionMode": mode.rawValue])
                return text
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

    private func recognize(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requireOnDevice: Bool,
        contextualStrings: [String]
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = requireOnDevice
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !didFinish else { return }
                if let result, result.isFinal {
                    didFinish = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    didFinish = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fail(_ message: String) -> String? {
        lastError = message
        state = .failed(message)
        return nil
    }
}
