import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, recorded(URL), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async {
        guard await requestPermission() else {
            state = .failed("Quyền microphone bị từ chối.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio, options: [])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-revenue-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.prepareToRecord()
            recorder.record()
            self.recorder = recorder
            elapsed = 0
            state = .recording
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed = recorder.currentTime }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard let recorder else { return }
        recorder.stop()
        timer?.invalidate()
        timer = nil
        state = .recorded(recorder.url)
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func cancel() {
        guard let recorder else { state = .idle; return }
        let url = recorder.url
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        try? FileManager.default.removeItem(at: url)
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
