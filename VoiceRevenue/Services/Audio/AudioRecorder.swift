import AVFoundation
import Foundation

struct AudioRecordingMetadata: Equatable {
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
    let formatID: UInt32?
    let fileSizeBytes: Int64

    var logPayload: [String: String] {
        [
            "durationSeconds": String(format: "%.3f", durationSeconds),
            "sampleRate": String(format: "%.0f", sampleRate),
            "channelCount": String(channelCount),
            "formatID": formatID.map(String.init) ?? "unknown",
            "fileSizeBytes": String(fileSizeBytes)
        ]
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, recorded(URL), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let fileManager = FileManager.default
    private let recordingsDirectory: URL

    override init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        recordingsDirectory = base.appendingPathComponent("VoiceRevenue/Recordings", isDirectory: true)
        super.init()
        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        lastRecordingURL = newestRecordingURL()
    }

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
            // .spokenAudio is a playback-oriented mode. .default is the safe recording mode here.
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)

            try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            let url = recordingsDirectory
                .appendingPathComponent("VoiceRevenue-Recording-\(UUID().uuidString).m4a")

            // Short accounting recordings favor capture fidelity over tiny file size.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                throw NSError(
                    domain: "VoiceRevenue.AudioRecorder",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Không thể bắt đầu ghi âm."]
                )
            }

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
        let url = recorder.url
        state = .recorded(url)
        lastRecordingURL = url
        self.recorder = nil
        pruneRecordings(keeping: url)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func cancel() {
        guard let recorder else { state = .idle; return }
        let url = recorder.url
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        try? fileManager.removeItem(at: url)
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func metadata(for url: URL) -> AudioRecordingMetadata? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let file = try? AVAudioFile(forReading: url) else {
            return AudioRecordingMetadata(
                durationSeconds: elapsed,
                sampleRate: 44_100,
                channelCount: 1,
                formatID: UInt32(kAudioFormatMPEG4AAC),
                fileSizeBytes: Int64(size)
            )
        }
        let format = file.fileFormat
        let frames = Double(file.length)
        let duration = format.sampleRate > 0 ? frames / format.sampleRate : elapsed
        let formatID: UInt32?
        if let value = format.settings[AVFormatIDKey] as? NSNumber {
            formatID = value.uint32Value
        } else {
            formatID = nil
        }
        return AudioRecordingMetadata(
            durationSeconds: duration,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            formatID: formatID,
            fileSizeBytes: Int64(size)
        )
    }

    private func newestRecordingURL() -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    private func pruneRecordings(keeping current: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file != current && file.pathExtension.lowercased() == "m4a" {
            try? fileManager.removeItem(at: file)
        }
    }
}
