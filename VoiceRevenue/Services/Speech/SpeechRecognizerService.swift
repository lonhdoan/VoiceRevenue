import AVFoundation
import Combine
import CryptoKit
import Foundation
import SherpaOnnx

enum SpeechRecognitionMode: String, Equatable {
    case localOffline
    case selfHostedReinforcement
}

enum SpeechRecognitionMethod: String, Equatable {
    case sherpaOnnxLocal
    case selfHostedRemote
}

enum SpeechStageStatus: String, Equatable {
    case notRun
    case running
    case success
    case failed
    case unsupported
    case notInstalled

    var displayName: String {
        switch self {
        case .notRun: return "Chưa chạy"
        case .running: return "Đang chạy"
        case .success: return "Thành công"
        case .failed: return "Lỗi"
        case .unsupported: return "Không hỗ trợ"
        case .notInstalled: return "Chưa cài"
        }
    }
}

enum LocalSpeechModelState: Equatable {
    case unknown
    case verifying
    case ready
    case missing(String)
    case invalid(String)

    var displayName: String {
        switch self {
        case .unknown: return "Chưa kiểm tra"
        case .verifying: return "Đang kiểm tra…"
        case .ready: return "Sẵn sàng"
        case .missing: return "Thiếu model"
        case .invalid: return "Model lỗi"
        }
    }
}

struct TranscriptArbitrationResult: Equatable {
    let selected: String
    let alternate: String?
    let source: SpeechRecognitionMethod
    let localScore: Double
    let remoteScore: Double?
}

enum SpeechTranscriptArbitrator {
    static func score(_ text: String, catalogProducts: [String]) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let normalized = VietnameseTextNormalizer.normalize(trimmed)
        var score = 1.0
        if VietnameseMoneyParser.firstAmount(in: trimmed) != nil { score += 2.0 }

        var exactHits = 0
        for product in catalogProducts {
            let candidate = VietnameseTextNormalizer.normalize(product)
            guard !candidate.isEmpty else { continue }
            if normalized.range(of: candidate) != nil {
                exactHits += 1
                if exactHits == 4 { break }
            }
        }
        score += Double(exactHits) * 0.5
        return score
    }

    static func choose(local: String, remote: String?, catalogProducts: [String]) -> TranscriptArbitrationResult {
        let localTrimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTrimmed = remote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localScore = score(localTrimmed, catalogProducts: catalogProducts)
        let remoteScore = remoteTrimmed.isEmpty ? nil : score(remoteTrimmed, catalogProducts: catalogProducts)

        if !remoteTrimmed.isEmpty,
           let remoteScore,
           (localTrimmed.isEmpty || remoteScore >= localScore + 1.0) {
            return TranscriptArbitrationResult(
                selected: remoteTrimmed,
                alternate: localTrimmed.isEmpty ? nil : localTrimmed,
                source: .selfHostedRemote,
                localScore: localScore,
                remoteScore: remoteScore
            )
        }
        return TranscriptArbitrationResult(
            selected: localTrimmed,
            alternate: remoteTrimmed.isEmpty || remoteTrimmed == localTrimmed ? nil : remoteTrimmed,
            source: .sherpaOnnxLocal,
            localScore: localScore,
            remoteScore: remoteScore
        )
    }
}

private enum OpenSpeechError: LocalizedError {
    case modelMissing(String)
    case modelInvalid(String)
    case audioUnreadable
    case audioTooLong
    case emptyTranscript
    case invalidRemoteEndpoint
    case remoteHTTP(Int)
    case remoteResponse

    var errorDescription: String? {
        switch self {
        case .modelMissing(let file): return "Thiếu model offline: \(file). Hãy chạy lại apply-v0.2.0.ps1."
        case .modelInvalid(let file): return "Model offline không đúng checksum: \(file)."
        case .audioUnreadable: return "Không thể đọc file ghi âm để nhận dạng offline."
        case .audioTooLong: return "Bản ghi quá dài cho chế độ offline trên thiết bị cũ."
        case .emptyTranscript: return "Model offline không nhận ra nội dung có nghĩa."
        case .invalidRemoteEndpoint: return "Địa chỉ máy chủ riêng không hợp lệ."
        case .remoteHTTP(let code): return "Máy chủ riêng trả HTTP \(code)."
        case .remoteResponse: return "Máy chủ riêng không trả transcript hợp lệ."
        }
    }
}

private struct LocalRecognitionOutput {
    let text: String
    let inferenceSeconds: Double
    let audioSeconds: Double
}

private final class SherpaLocalEngine {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var modelPaths: [String: URL] = [:]

    func recognize(samples: [Float], sampleRate: Int, files: [String: URL]) throws -> LocalRecognitionOutput {
        let recognizer = try recognizerForFiles(files)
        let start = ProcessInfo.processInfo.systemUptime
        let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        return LocalRecognitionOutput(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            inferenceSeconds: elapsed,
            audioSeconds: Double(samples.count) / Double(sampleRate)
        )
    }

    func reset() {
        recognizer = nil
        modelPaths = [:]
    }

    private func recognizerForFiles(_ files: [String: URL]) throws -> SherpaOnnxOfflineRecognizer {
        if let recognizer, modelPaths == files { return recognizer }

        guard let encoder = files["encoder-epoch-12-avg-8.int8.onnx"],
              let decoder = files["decoder-epoch-12-avg-8.onnx"],
              let joiner = files["joiner-epoch-12-avg-8.int8.onnx"],
              let tokens = files["tokens.txt"] else {
            throw OpenSpeechError.modelMissing(SpeechRecognizerService.modelName)
        }

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: encoder.path,
            decoder: decoder.path,
            joiner: joiner.path
        )
        let model = sherpaOnnxOfflineModelConfig(
            tokens: tokens.path,
            transducer: transducer,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        let feat = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: feat,
            modelConfig: model,
            decodingMethod: "greedy_search"
        )
        let created = SherpaOnnxOfflineRecognizer(config: &config)
        recognizer = created
        modelPaths = files
        return created
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

    static let engineName = "sherpa-onnx"
    static let engineVersion = "1.13.6"
    static let modelName = "sherpa-onnx-zipformer-vi-int8-2025-04-20"
    static let modelArchiveSHA256 = "48d0fdc9b3515eb9b00c4dfec2883207ee5ebe5c95b1959e7afce87fc3391938"

    private enum Keys {
        static let remoteEnabled = "openSpeech.remote.enabled.v0.2.0"
        static let remoteURL = "openSpeech.remote.url.v0.2.0"
        static let remoteModel = "openSpeech.remote.model.v0.2.0"
    }

    private static let requiredFiles: [(name: String, sha256: String?)] = [
        ("encoder-epoch-12-avg-8.int8.onnx", "b3abdef7a660fea7faf5e076b3c7613b0fc98406707103784d018189bb522124"),
        ("decoder-epoch-12-avg-8.onnx", "d1d27cca84c824a8acf5ce6edf0f2c0880cfe295d2e69b95134de1707e1d9998"),
        ("joiner-epoch-12-avg-8.int8.onnx", nil),
        ("tokens.txt", nil),
        ("bpe.model", "289dbb44527c13c419ae3a4d8ce6a349f01a97f8777e69934a77e3692d2f10db")
    ]

    @Published private(set) var state: State = .idle
    @Published private(set) var modelState: LocalSpeechModelState = .unknown
    @Published private(set) var localStatus: SpeechStageStatus = .notRun
    @Published private(set) var remoteStatus: SpeechStageStatus = .notRun
    @Published private(set) var finalStatus: SpeechStageStatus = .notRun
    @Published private(set) var lastRecognitionMode: SpeechRecognitionMode = .localOffline
    @Published private(set) var lastRecognitionMethod: SpeechRecognitionMethod = .sherpaOnnxLocal
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorDomain = ""
    @Published private(set) var lastErrorCode = ""
    @Published private(set) var lastErrorDescription = ""
    @Published private(set) var localTranscript = ""
    @Published private(set) var remoteTranscript = ""
    @Published private(set) var alternateTranscript: String?
    @Published private(set) var lastInferenceSeconds: Double?
    @Published private(set) var lastRealtimeFactor: Double?

    @Published var remoteReinforcementEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteReinforcementEnabled, forKey: Keys.remoteEnabled) }
    }
    @Published var remoteEndpointURLString: String {
        didSet { UserDefaults.standard.set(remoteEndpointURLString, forKey: Keys.remoteURL) }
    }
    @Published var remoteModelName: String {
        didSet { UserDefaults.standard.set(remoteModelName, forKey: Keys.remoteModel) }
    }

    weak var diagnostics: DiagnosticLogger?

    private let inferenceQueue = DispatchQueue(label: "VoiceRevenue.SherpaOnnxInference", qos: .userInitiated)
    private let localEngine = SherpaLocalEngine()

    init() {
        let defaults = UserDefaults.standard
        remoteReinforcementEnabled = defaults.bool(forKey: Keys.remoteEnabled)
        remoteEndpointURLString = defaults.string(forKey: Keys.remoteURL) ?? ""
        remoteModelName = defaults.string(forKey: Keys.remoteModel) ?? "whisper-1"
    }

    var isAvailable: Bool {
        if case .ready = modelState { return true }
        return bundledModelDirectory() != nil
    }

    var supportsOnDevice: Bool { isAvailable }
    var liveStatus: SpeechStageStatus { localStatus }
    var replayStatus: SpeechStageStatus { remoteStatus }
    var onDeviceStatus: SpeechStageStatus { .unsupported }
    var localFallbackStatus: SpeechStageStatus { localStatus }

    func refreshModelState() async {
        modelState = .verifying
        do {
            _ = try await verifyAndResolveModelFiles()
            modelState = .ready
        } catch let error as OpenSpeechError {
            switch error {
            case .modelMissing(let file): modelState = .missing(file)
            case .modelInvalid(let file): modelState = .invalid(file)
            default: modelState = .invalid(error.localizedDescription)
            }
        } catch {
            modelState = .invalid(error.localizedDescription)
        }
    }

    func resetForNewRecording() {
        state = .idle
        localStatus = .notRun
        remoteStatus = .notRun
        finalStatus = .notRun
        localTranscript = ""
        remoteTranscript = ""
        alternateTranscript = nil
        lastError = nil
        lastErrorDomain = ""
        lastErrorCode = ""
        lastErrorDescription = ""
        lastInferenceSeconds = nil
        lastRealtimeFactor = nil
    }

    func transcribe(
        url: URL,
        catalogProducts: [String] = [],
        allowRemoteReinforcement: Bool = true
    ) async -> String? {
        state = .recognizing
        localStatus = .running
        remoteStatus = .notRun
        finalStatus = .running
        lastRecognitionMode = .localOffline
        lastRecognitionMethod = .sherpaOnnxLocal
        lastError = nil
        alternateTranscript = nil

        diagnostics?.log(event: "speech.pipeline.started", payload: [
            "engine": Self.engineName,
            "engineVersion": Self.engineVersion,
            "model": Self.modelName,
            "file": url.lastPathComponent,
            "remoteEnabled": String(remoteReinforcementEnabled && allowRemoteReinforcement)
        ])
        diagnostics?.log(event: "speech.local.started", payload: [
            "engine": Self.engineName,
            "model": Self.modelName,
            "fileExists": String(FileManager.default.fileExists(atPath: url.path))
        ])

        do {
            let local = try await recognizeLocally(url: url)
            let localText = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !localText.isEmpty else { throw OpenSpeechError.emptyTranscript }

            localTranscript = localText
            localStatus = .success
            modelState = .ready
            lastInferenceSeconds = local.inferenceSeconds
            lastRealtimeFactor = local.audioSeconds > 0 ? local.inferenceSeconds / local.audioSeconds : nil
            diagnostics?.log(event: "speech.local.succeeded", payload: [
                "transcript": localText,
                "inferenceSeconds": String(format: "%.3f", local.inferenceSeconds),
                "audioSeconds": String(format: "%.3f", local.audioSeconds),
                "rtf": lastRealtimeFactor.map { String(format: "%.3f", $0) } ?? "nil"
            ])

            var remoteText: String?
            if allowRemoteReinforcement && remoteReinforcementEnabled && !remoteEndpointURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remoteStatus = .running
                diagnostics?.log(event: "speech.remote.started", payload: safeRemoteEndpointPayload())
                do {
                    let samples = try await loadMonoSamples(url: url)
                    let wav = Self.makePCM16WAV(samples: samples.samples, sampleRate: samples.sampleRate)
                    let remote = try await requestRemoteTranscript(wavData: wav)
                    let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        remoteText = trimmed
                        remoteTranscript = trimmed
                        remoteStatus = .success
                        diagnostics?.log(event: "speech.remote.succeeded", payload: ["transcript": trimmed])
                    } else {
                        remoteStatus = .failed
                    }
                } catch {
                    remoteStatus = .failed
                    diagnostics?.log(event: "speech.remote.failed", payload: errorPayload(error))
                }
            }

            let decision = SpeechTranscriptArbitrator.choose(
                local: localText,
                remote: remoteText,
                catalogProducts: catalogProducts
            )
            alternateTranscript = decision.alternate
            lastRecognitionMethod = decision.source
            lastRecognitionMode = decision.source == .sherpaOnnxLocal ? .localOffline : .selfHostedReinforcement
            finalStatus = .success
            state = .recognized(decision.selected)
            diagnostics?.log(event: "speech.arbitration", payload: [
                "selectedSource": decision.source.rawValue,
                "localScore": String(format: "%.2f", decision.localScore),
                "remoteScore": decision.remoteScore.map { String(format: "%.2f", $0) } ?? "nil",
                "alternateAvailable": String(decision.alternate != nil)
            ])
            diagnostics?.log(event: "speech.pipeline.succeeded", payload: [
                "source": decision.source.rawValue,
                "transcript": decision.selected
            ])
            return decision.selected
        } catch {
            localStatus = error is OpenSpeechError ? .failed : .failed
            finalStatus = .failed
            state = .failed(error.localizedDescription)
            recordError(error)
            diagnostics?.log(event: "speech.local.failed", payload: errorPayload(error))
            diagnostics?.log(event: "speech.pipeline.failed", payload: errorPayload(error))
            return nil
        }
    }

    func transcribeLocalOnly(url: URL, catalogProducts: [String] = []) async -> String? {
        await transcribe(url: url, catalogProducts: catalogProducts, allowRemoteReinforcement: false)
    }

    func activateAlternate(currentText: String) -> String? {
        guard let alternate = alternateTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !alternate.isEmpty else { return nil }
        let current = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        alternateTranscript = current.isEmpty ? nil : current
        diagnostics?.log(event: "speech.alternate.selected", payload: ["transcript": alternate])
        return alternate
    }

    private func recognizeLocally(url: URL) async throws -> LocalRecognitionOutput {
        let files = try await verifyAndResolveModelFiles()
        let loaded = try await loadMonoSamples(url: url)
        guard loaded.samples.count <= loaded.sampleRate * 180 else { throw OpenSpeechError.audioTooLong }

        let engine = localEngine
        return try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    continuation.resume(returning: try engine.recognize(
                        samples: loaded.samples,
                        sampleRate: loaded.sampleRate,
                        files: files
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func verifyAndResolveModelFiles() async throws -> [String: URL] {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    guard let directory = Self.findBundledModelDirectory() else {
                        throw OpenSpeechError.modelMissing(Self.modelName)
                    }
                    var resolved: [String: URL] = [:]
                    for item in Self.requiredFiles {
                        let url = directory.appendingPathComponent(item.name)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            throw OpenSpeechError.modelMissing(item.name)
                        }
                        if let expected = item.sha256 {
                            let actual = try Self.sha256(url: url)
                            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                                throw OpenSpeechError.modelInvalid(item.name)
                            }
                        }
                        resolved[item.name] = url
                    }
                    continuation.resume(returning: resolved)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func bundledModelDirectory() -> URL? { Self.findBundledModelDirectory() }

    nonisolated private static func findBundledModelDirectory() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("SherpaVI", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("SherpaVI", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadMonoSamples(url: URL) async throws -> (samples: [Float], sampleRate: Int) {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    continuation.resume(returning: try Self.readMono16kSamples(url: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func readMono16kSamples(url: URL) throws -> (samples: [Float], sampleRate: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OpenSpeechError.audioUnreadable }
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard file.length > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw OpenSpeechError.audioUnreadable
        }
        try file.read(into: inputBuffer)

        let targetRate = 16_000.0
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw OpenSpeechError.audioUnreadable
        }

        let ratio = targetRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1, ceil(Double(inputBuffer.frameLength) * ratio) + 1024))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw OpenSpeechError.audioUnreadable
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if supplied {
                outputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error || conversionError != nil { throw conversionError ?? OpenSpeechError.audioUnreadable }
        guard let channel = outputBuffer.floatChannelData?[0] else { throw OpenSpeechError.audioUnreadable }
        let count = Int(outputBuffer.frameLength)
        return (Array(UnsafeBufferPointer(start: channel, count: count)), 16_000)
    }

    private func requestRemoteTranscript(wavData: Data) async throws -> String {
        guard let endpoint = validatedRemoteEndpoint() else { throw OpenSpeechError.invalidRemoteEndpoint }
        let boundary = "VoiceRevenue-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(remoteModelName)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nvi\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenSpeechError.remoteResponse }
        guard (200...299).contains(http.statusCode) else { throw OpenSpeechError.remoteHTTP(http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw OpenSpeechError.remoteResponse }
        return text
    }

    private func validatedRemoteEndpoint() -> URL? {
        guard let url = URL(string: remoteEndpointURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        guard scheme == "http", Self.isLocalHost(host) else { return nil }
        return url
    }

    private func safeRemoteEndpointPayload() -> [String: String] {
        guard let url = validatedRemoteEndpoint() else { return ["configured": "false"] }
        return [
            "configured": "true",
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "path": url.path,
            "model": remoteModelName
        ]
    }

    nonisolated private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    nonisolated private static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func makePCM16WAV(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            var value = Int16(clipped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func appendASCII(_ value: String) { data.append(Data(value.utf8)) }
        func appendUInt32(_ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func appendUInt16(_ value: UInt16) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 2)) }
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendASCII("WAVEfmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private func recordError(_ error: Error) {
        let ns = error as NSError
        lastError = error.localizedDescription
        lastErrorDomain = ns.domain
        lastErrorCode = String(ns.code)
        lastErrorDescription = ns.localizedDescription
        switch error {
        case OpenSpeechError.modelMissing(let file): modelState = .missing(file)
        case OpenSpeechError.modelInvalid(let file): modelState = .invalid(file)
        default: break
        }
    }

    private func errorPayload(_ error: Error) -> [String: String] {
        let ns = error as NSError
        return [
            "engine": Self.engineName,
            "model": Self.modelName,
            "domain": ns.domain,
            "code": String(ns.code),
            "description": ns.localizedDescription,
            "failureReason": ns.localizedFailureReason ?? ""
        ]
    }
}
