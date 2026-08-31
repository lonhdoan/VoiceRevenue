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

private final class AudioCaptureSink {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let consumer: ((AVAudioPCMBuffer) -> Void)?

    init(file: AVAudioFile, consumer: ((AVAudioPCMBuffer) -> Void)?) {
        self.file = file
        self.consumer = consumer
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let targetFile = file
        lock.unlock()
        try? targetFile?.write(from: buffer)
        consumer?(buffer)
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    enum State: Equatable { case idle, recording, recorded(URL), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?

    private var audioEngine: AVAudioEngine?
    private var captureSink: AudioCaptureSink?
    private var timer: Timer?
    private var recordingStartedAt: Date?
    private var activeRecordingURL: URL?
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

    /// Starts a single AVAudioEngine microphone pipeline.
    /// The same PCM buffers are written to a local CAF file and optionally forwarded to live Speech.
    func start(bufferConsumer: ((AVAudioPCMBuffer) -> Void)? = nil) async {
        guard await requestPermission() else {
            state = .failed("Quyền microphone bị từ chối.")
            return
        }

        do {
            stopEngineIfNeeded()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])

            try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                throw NSError(
                    domain: "VoiceRevenue.AudioRecorder",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone không trả về audio format hợp lệ."]
                )
            }

            let url = recordingsDirectory
                .appendingPathComponent("VoiceRevenue-Recording-\(UUID().uuidString).caf")
            let audioFile = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)
            activeRecordingURL = url
            let sink = AudioCaptureSink(file: audioFile, consumer: bufferConsumer)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                sink.consume(buffer)
            }

            engine.prepare()
            try engine.start()

            audioEngine = engine
            captureSink = sink
            recordingStartedAt = Date()
            elapsed = 0
            state = .recording

            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let started = self.recordingStartedAt else { return }
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
        } catch {
            stopEngineIfNeeded()
            state = .failed(error.localizedDescription)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stop() {
        guard case .recording = state, let engine = audioEngine else { return }

        let url = activeRecordingURL
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        captureSink?.close()
        captureSink = nil
        audioEngine = nil

        timer?.invalidate()
        timer = nil
        if let started = recordingStartedAt {
            elapsed = Date().timeIntervalSince(started)
        }
        recordingStartedAt = nil
        activeRecordingURL = nil

        if let url, fileManager.fileExists(atPath: url.path) {
            state = .recorded(url)
            lastRecordingURL = url
            pruneRecordings(keeping: url)
        } else {
            state = .failed("Không tìm thấy file ghi âm sau khi dừng.")
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func cancel() {
        let possibleURL = activeRecordingURL
        stopEngineIfNeeded()
        if let possibleURL {
            try? fileManager.removeItem(at: possibleURL)
        }
        state = .idle
        elapsed = 0
        recordingStartedAt = nil
        activeRecordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func metadata(for url: URL) -> AudioRecordingMetadata? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let file = try? AVAudioFile(forReading: url) else {
            return AudioRecordingMetadata(
                durationSeconds: elapsed,
                sampleRate: 0,
                channelCount: 0,
                formatID: nil,
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

    private func stopEngineIfNeeded() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        captureSink?.close()
        captureSink = nil
        audioEngine = nil
        timer?.invalidate()
        timer = nil
    }

    private func newestRecordingURL() -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { ["caf", "m4a"].contains($0.pathExtension.lowercased()) }
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
        let currentPath = current.standardizedFileURL.path
        for file in files where file.standardizedFileURL.path != currentPath && ["caf", "m4a"].contains(file.pathExtension.lowercased()) {
            try? fileManager.removeItem(at: file)
        }
    }
}
