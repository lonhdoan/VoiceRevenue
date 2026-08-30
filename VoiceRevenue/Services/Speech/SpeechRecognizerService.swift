import Foundation
import Speech

@MainActor
final class SpeechRecognizerService: ObservableObject {
    enum State: Equatable { case idle, recognizing, recognized(String), failed(String) }

    @Published private(set) var state: State = .idle
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))

    var isAvailable: Bool { recognizer?.isAvailable ?? false }
    var supportsOnDevice: Bool {
        if #available(iOS 13.0, *) { return recognizer?.supportsOnDeviceRecognition ?? false }
        return false
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribe(url: URL) async -> String? {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            state = .failed("Speech Recognition chưa được cấp quyền.")
            return nil
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Nhận dạng giọng nói hiện không khả dụng.")
            return nil
        }

        state = .recognizing
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return await withCheckedContinuation { continuation in
            var didFinish = false
            recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard !didFinish else { return }
                if let result, result.isFinal {
                    didFinish = true
                    let text = result.bestTranscription.formattedString
                    Task { @MainActor in self?.state = .recognized(text) }
                    continuation.resume(returning: text)
                } else if let error {
                    didFinish = true
                    Task { @MainActor in self?.state = .failed(error.localizedDescription) }
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
