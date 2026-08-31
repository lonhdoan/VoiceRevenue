import AVFoundation
import Foundation
import Network
import Speech

enum SpeechRecognitionMode: String, Equatable {
    case online
    case onDeviceFallback
}

enum SpeechRecognitionMethod: String, Equatable {
    case liveAudioBuffer
    case replayAudioBuffer
    case onDeviceAudioBuffer
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


struct LiveTranscriptSelection: Equatable {
    let text: String
    let source: String
}

enum LiveTranscriptSelector {
    static func select(final: String?, partial: String?) -> LiveTranscriptSelection? {
        let finalText = final?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !finalText.isEmpty {
            return LiveTranscriptSelection(text: finalText, source: "final")
        }
        let partialText = partial?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !partialText.isEmpty {
            return LiveTranscriptSelection(text: partialText, source: "partial")
        }
        return nil
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
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Apple Speech trả về transcript rỗng."
        case .invalidAudioFile:
            return "Không thể đọc file ghi âm để nhận diện giọng nói."
        case .unableToCreatePCMBuffer:
            return "Không thể tạo audio buffer để thử nhận diện lại."
        case .timedOut:
            return "Nhận diện giọng nói quá thời gian chờ."
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

private final class SpeechResultBox {
    private let lock = NSLock()
    private var bestResult: SpeechPassResult?
    private var finalResult: SpeechPassResult?
    private var storedError: NSError?
    private var completed = false

    func reset() {
        lock.lock()
        bestResult = nil
        finalResult = nil
        storedError = nil
        completed = false
        lock.unlock()
    }

    func update(_ result: SpeechPassResult, isFinal: Bool) {
        lock.lock()
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            bestResult = result
            if isFinal { finalResult = result }
        }
        lock.unlock()
    }

    func setErrorIfActive(_ error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        storedError = error as NSError
        return true
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    func snapshot() -> (best: SpeechPassResult?, final: SpeechPassResult?, error: NSError?, completed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bestResult, finalResult, storedError, completed)
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

    private enum StatusKeys {
        static let live = "speechStatus.live.v0.1.4"
        static let replay = "speechStatus.replay.v0.1.4"
        static let onDevice = "speechStatus.onDevice.v0.1.4"
        static let local = "speechStatus.local.v0.1.4"
        static let final = "speechStatus.final.v0.1.4"
        static let errorDomain = "speechStatus.errorDomain.v0.1.4"
        static let errorCode = "speechStatus.errorCode.v0.1.4"
        static let errorDescription = "speechStatus.errorDescription.v0.1.4"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var lastRecognitionMode: SpeechRecognitionMode = .online
    @Published private(set) var lastRecognitionMethod: SpeechRecognitionMethod = .liveAudioBuffer
    @Published private(set) var lastError: String?
    @Published private(set) var liveStatus: SpeechStageStatus
    @Published private(set) var replayStatus: SpeechStageStatus
    @Published private(set) var onDeviceStatus: SpeechStageStatus
    @Published private(set) var localFallbackStatus: SpeechStageStatus
    @Published private(set) var finalStatus: SpeechStageStatus
    @Published private(set) var lastErrorDomain: String
    @Published private(set) var lastErrorCode: String
    @Published private(set) var lastErrorDescription: String

    weak var diagnostics: DiagnosticLogger?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "VoiceRevenue.NetworkMonitor")
    private var networkAvailable = true

    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private let liveResultBox = SpeechResultBox()
    private var replayTask: SFSpeechRecognitionTask?

    init() {
        let defaults = UserDefaults.standard
        liveStatus = SpeechStageStatus(rawValue: defaults.string(forKey: StatusKeys.live) ?? "") ?? .notRun
        replayStatus = SpeechStageStatus(rawValue: defaults.string(forKey: StatusKeys.replay) ?? "") ?? .notRun
        onDeviceStatus = SpeechStageStatus(rawValue: defaults.string(forKey: StatusKeys.onDevice) ?? "") ?? .notRun
        localFallbackStatus = .notInstalled
        finalStatus = SpeechStageStatus(rawValue: defaults.string(forKey: StatusKeys.final) ?? "") ?? .notRun
        lastErrorDomain = defaults.string(forKey: StatusKeys.errorDomain) ?? ""
        lastErrorCode = defaults.string(forKey: StatusKeys.errorCode) ?? ""
        lastErrorDescription = defaults.string(forKey: StatusKeys.errorDescription) ?? ""

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

    /// Starts the primary live Speech path. The returned closure is deliberately independent of
    /// MainActor state so AudioRecorder can append microphone PCM buffers directly from its audio tap.
    func beginLiveRecognition(
        contextualStrings: [String] = []
    ) async -> ((AVAudioPCMBuffer) -> Void)? {
        resetStatusesForNewPipeline()
        state = .recognizing
        lastError = nil
        liveTranscript = ""
        liveResultBox.reset()

        let auth = await requestAuthorization()
        guard auth == .authorized else {
            let error = NSError(
                domain: "VoiceRevenue.SpeechAuthorization",
                code: Int(auth.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Speech Recognition chưa được cấp quyền."]
            )
            recordFailure(error, stage: "speech.live", method: .liveAudioBuffer, requireOnDevice: false)
            return nil
        }
        guard let recognizer else {
            let error = NSError(
                domain: "VoiceRevenue.SpeechRecognizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Không tạo được bộ nhận dạng tiếng Việt vi-VN."]
            )
            recordFailure(error, stage: "speech.live", method: .liveAudioBuffer, requireOnDevice: false)
            return nil
        }
        guard recognizer.isAvailable else {
            let error = NSError(
                domain: "VoiceRevenue.SpeechRecognizer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Apple Speech online hiện không khả dụng."]
            )
            recordFailure(error, stage: "speech.live", method: .liveAudioBuffer, requireOnDevice: false)
            return nil
        }

        cancelLiveRecognition(reason: "replace_previous_live_session", logCancellation: false)

        let request = SFSpeechAudioBufferRecognitionRequest()
        configure(
            request,
            requireOnDevice: false,
            contextualStrings: contextualStrings,
            partialResults: true
        )

        liveRequest = request
        lastRecognitionMode = .online
        lastRecognitionMethod = .liveAudioBuffer
        setStageStatus(.running, for: .liveAudioBuffer)

        diagnostics?.log(event: "speech.pipeline.started", payload: [
            "networkAvailable": String(networkAvailable),
            "locale": recognizer.locale.identifier,
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(supportsOnDevice),
            "contextualCount": String(request.contextualStrings.count)
        ])
        diagnostics?.log(event: "speech.live.started", payload: [
            "method": SpeechRecognitionMethod.liveAudioBuffer.rawValue,
            "requiresOnDevice": "false",
            "locale": recognizer.locale.identifier,
            "contextualCount": String(request.contextualStrings.count)
        ])

        let resultBox = liveResultBox
        liveTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let pass = Self.passResult(from: result)
                resultBox.update(pass, isFinal: result.isFinal)
                let trimmed = pass.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.liveTranscript = trimmed
                        self.diagnostics?.log(
                            event: result.isFinal ? "speech.live.final" : "speech.live.partial",
                            payload: [
                                "transcript": trimmed,
                                "confidence": pass.confidenceDescription,
                                "segmentConfidences": pass.segmentConfidenceDescription
                            ]
                        )
                    }
                }
            }

            if let error, resultBox.setErrorIfActive(error) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let snapshot = resultBox.snapshot()
                    if snapshot.final == nil && !snapshot.completed {
                        self.recordFailure(
                            error,
                            stage: "speech.live",
                            method: .liveAudioBuffer,
                            requireOnDevice: false
                        )
                    }
                }
            }
        }

        // Capturing request, rather than self, keeps the real-time audio callback independent of
        // actor hopping and prevents loss/reordering of microphone buffers.
        return { buffer in
            request.append(buffer)
        }
    }

    /// Ends live audio and waits briefly for Apple's final callback. If Apple never marks a result
    /// final, a useful non-empty partial transcript is preserved instead of being discarded.
    func finishLiveRecognition(timeoutSeconds: Double = 2.0) async -> String? {
        guard let request = liveRequest else { return nil }
        request.endAudio()

        let timeout = max(0.5, min(timeoutSeconds, 4.0))
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let snapshot = liveResultBox.snapshot()
            if snapshot.final != nil || (snapshot.error != nil && snapshot.best == nil) {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let snapshot = liveResultBox.snapshot()
        let selection = LiveTranscriptSelector.select(
            final: snapshot.final?.text,
            partial: snapshot.best?.text
        )
        let trimmed = selection?.text ?? ""
        let source = selection?.source ?? "none"
        let selected = snapshot.final ?? snapshot.best

        liveResultBox.markCompleted()
        liveTask?.cancel()
        liveTask = nil
        liveRequest = nil

        guard !trimmed.isEmpty else {
            if snapshot.error == nil {
                let error = SpeechHotfixError.emptyTranscript
                recordFailure(
                    error,
                    stage: "speech.live",
                    method: .liveAudioBuffer,
                    requireOnDevice: false
                )
            }
            return nil
        }

        liveTranscript = trimmed
        state = .recognized(trimmed)
        lastError = nil
        setStageStatus(.success, for: .liveAudioBuffer)
        setFinalStatus(.success)
        diagnostics?.log(event: "speech.live.succeeded", payload: [
            "source": source,
            "transcript": trimmed,
            "confidence": selected?.confidenceDescription ?? "0.000",
            "segmentConfidences": selected?.segmentConfidenceDescription ?? ""
        ])
        diagnostics?.log(event: "speech.pipeline.succeeded", payload: [
            "source": "liveAudioBuffer",
            "transcript": trimmed
        ])
        return trimmed
    }

    func cancelLiveRecognition(reason: String, logCancellation: Bool = true) {
        liveRequest?.endAudio()
        liveResultBox.markCompleted()
        liveTask?.cancel()
        liveTask = nil
        liveRequest = nil
        if logCancellation {
            diagnostics?.log(event: "speech.live.cancelled", payload: ["reason": reason])
        }
    }

    /// Replays an already saved recording through a fresh Apple Speech buffer request. This is the
    /// recovery path after live Speech returned no usable text, and it is also used by manual Retry.
    func transcribe(
        url: URL,
        initialContextualStrings: [String] = [],
        catalogProducts: [String] = [],
        preferBufferFirst: Bool = true
    ) async -> String? {
        let auth = await requestAuthorization()
        guard auth == .authorized else {
            return pipelineFailure("Speech Recognition chưa được cấp quyền.")
        }
        guard let recognizer else {
            return pipelineFailure("Không tạo được bộ nhận dạng tiếng Việt vi-VN.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return pipelineFailure("File ghi âm không còn tồn tại để nhận diện.")
        }

        state = .recognizing
        lastError = nil
        let context = cappedContext(initialContextualStrings)
        diagnostics?.log(event: "speech.recovery.started", payload: [
            "file": url.lastPathComponent,
            "networkAvailable": String(networkAvailable),
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(supportsOnDevice),
            "contextualCount": String(context.count),
            "catalogCount": String(catalogProducts.count),
            "preferBufferFirst": String(preferBufferFirst)
        ])

        var latestError: Error?

        if recognizer.isAvailable {
            lastRecognitionMode = .online
            lastRecognitionMethod = .replayAudioBuffer
            setStageStatus(.running, for: .replayAudioBuffer)
            diagnostics?.log(event: "speech.replay.started", payload: stagePayload(
                method: .replayAudioBuffer,
                requireOnDevice: false,
                recognizer: recognizer,
                contextualCount: context.count,
                file: url
            ))

            do {
                let result = try await recognizeAudioBuffer(
                    url: url,
                    recognizer: recognizer,
                    requireOnDevice: false,
                    contextualStrings: context
                )
                if let accepted = accept(result, method: .replayAudioBuffer, mode: .online) {
                    setStageStatus(.success, for: .replayAudioBuffer)
                    setFinalStatus(.success)
                    diagnostics?.log(event: "speech.replay.succeeded", payload: [
                        "transcript": accepted,
                        "confidence": result.confidenceDescription,
                        "segmentConfidences": result.segmentConfidenceDescription
                    ])
                    diagnostics?.log(event: "speech.pipeline.succeeded", payload: [
                        "source": "replayAudioBuffer",
                        "transcript": accepted
                    ])
                    return accepted
                }
            } catch {
                latestError = error
                recordFailure(error, stage: "speech.replay", method: .replayAudioBuffer, requireOnDevice: false)
            }
        } else {
            setStageStatus(.failed, for: .replayAudioBuffer)
            diagnostics?.log(event: "speech.replay.failed", payload: [
                "method": SpeechRecognitionMethod.replayAudioBuffer.rawValue,
                "reason": "recognizer_unavailable"
            ])
        }

        if supportsOnDevice {
            lastRecognitionMode = .onDeviceFallback
            lastRecognitionMethod = .onDeviceAudioBuffer
            setStageStatus(.running, for: .onDeviceAudioBuffer)
            diagnostics?.log(event: "speech.ondevice.started", payload: stagePayload(
                method: .onDeviceAudioBuffer,
                requireOnDevice: true,
                recognizer: recognizer,
                contextualCount: context.count,
                file: url
            ))

            do {
                let result = try await recognizeAudioBuffer(
                    url: url,
                    recognizer: recognizer,
                    requireOnDevice: true,
                    contextualStrings: context
                )
                if let accepted = accept(result, method: .onDeviceAudioBuffer, mode: .onDeviceFallback) {
                    setStageStatus(.success, for: .onDeviceAudioBuffer)
                    setFinalStatus(.success)
                    diagnostics?.log(event: "speech.ondevice.succeeded", payload: [
                        "transcript": accepted,
                        "confidence": result.confidenceDescription,
                        "segmentConfidences": result.segmentConfidenceDescription
                    ])
                    diagnostics?.log(event: "speech.pipeline.succeeded", payload: [
                        "source": "onDeviceAudioBuffer",
                        "transcript": accepted
                    ])
                    return accepted
                }
            } catch {
                latestError = error
                recordFailure(error, stage: "speech.ondevice", method: .onDeviceAudioBuffer, requireOnDevice: true)
            }
        } else {
            setStageStatus(.unsupported, for: .onDeviceAudioBuffer)
            diagnostics?.log(event: "speech.ondevice.unsupported", payload: [
                "locale": recognizer.locale.identifier,
                "supportsOnDeviceRecognition": "false"
            ])
        }

        return pipelineFailure(latestError?.localizedDescription ?? "Không nhận dạng được giọng nói.")
    }

    private func recognizeAudioBuffer(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requireOnDevice: Bool,
        contextualStrings: [String]
    ) async throws -> SpeechPassResult {
        let request = SFSpeechAudioBufferRecognitionRequest()
        configure(
            request,
            requireOnDevice: requireOnDevice,
            contextualStrings: contextualStrings,
            partialResults: true
        )
        let gate = SpeechContinuationGate()
        let resultBox = SpeechResultBox()

        replayTask?.cancel()
        replayTask = nil

        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechPassResult, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let pass = Self.passResult(from: result)
                        resultBox.update(pass, isFinal: result.isFinal)
                        if result.isFinal, gate.claim() {
                            continuation.resume(returning: pass)
                            return
                        }
                    }

                    if let error {
                        resultBox.setErrorIfActive(error)
                        if gate.claim() {
                            let snapshot = resultBox.snapshot()
                            if let best = snapshot.best,
                               !best.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                continuation.resume(returning: best)
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                self.replayTask = task

                do {
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

                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                    guard gate.claim() else { return }
                    let snapshot = resultBox.snapshot()
                    task.cancel()
                    if let best = snapshot.best,
                       !best.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(returning: best)
                    } else {
                        continuation.resume(throwing: SpeechHotfixError.timedOut)
                    }
                }
            }
            replayTask = nil
            return result
        } catch {
            replayTask = nil
            throw error
        }
    }

    private func configure(
        _ request: SFSpeechRecognitionRequest,
        requireOnDevice: Bool,
        contextualStrings: [String],
        partialResults: Bool
    ) {
        request.shouldReportPartialResults = partialResults
        request.taskHint = .dictation
        request.contextualStrings = cappedContext(contextualStrings)
        request.requiresOnDeviceRecognition = requireOnDevice
    }

    nonisolated private static func passResult(from result: SFSpeechRecognitionResult) -> SpeechPassResult {
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

    private func accept(
        _ result: SpeechPassResult,
        method: SpeechRecognitionMethod,
        mode: SpeechRecognitionMode
    ) -> String? {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lastRecognitionMethod = method
        lastRecognitionMode = mode
        state = .recognized(trimmed)
        lastError = nil
        liveTranscript = trimmed
        return trimmed
    }

    private func cappedContext(_ values: [String]) -> [String] {
        Array(
            VietnameseTextNormalizer
                .normalizedVocabulary(values)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(100)
        )
    }

    private func stagePayload(
        method: SpeechRecognitionMethod,
        requireOnDevice: Bool,
        recognizer: SFSpeechRecognizer,
        contextualCount: Int,
        file: URL
    ) -> [String: String] {
        [
            "method": method.rawValue,
            "requiresOnDevice": String(requireOnDevice),
            "locale": recognizer.locale.identifier,
            "recognizerAvailable": String(recognizer.isAvailable),
            "onDeviceSupported": String(supportsOnDevice),
            "contextualCount": String(contextualCount),
            "file": file.lastPathComponent,
            "fileExists": String(FileManager.default.fileExists(atPath: file.path))
        ]
    }

    private func recordFailure(
        _ error: Error,
        stage: String,
        method: SpeechRecognitionMethod,
        requireOnDevice: Bool
    ) {
        let nsError = error as NSError
        lastError = nsError.localizedDescription
        lastRecognitionMethod = method
        lastRecognitionMode = requireOnDevice ? .onDeviceFallback : .online
        rememberError(nsError)
        setStageStatus(.failed, for: method)

        var payload: [String: String] = [
            "method": method.rawValue,
            "recognitionMode": requireOnDevice ? SpeechRecognitionMode.onDeviceFallback.rawValue : SpeechRecognitionMode.online.rawValue,
            "requiresOnDevice": String(requireOnDevice),
            "domain": nsError.domain,
            "code": String(nsError.code),
            "description": nsError.localizedDescription,
            "failureReason": nsError.localizedFailureReason ?? "",
            "locale": recognizer?.locale.identifier ?? "vi-VN",
            "recognizerAvailable": String(recognizer?.isAvailable ?? false),
            "onDeviceSupported": String(supportsOnDevice)
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            payload["underlyingDomain"] = underlying.domain
            payload["underlyingCode"] = String(underlying.code)
            payload["underlyingDescription"] = underlying.localizedDescription
        }
        diagnostics?.log(event: "\(stage).failed", payload: payload)
    }

    private func pipelineFailure(_ message: String) -> String? {
        lastError = message
        state = .failed(message)
        setFinalStatus(.failed)
        diagnostics?.log(event: "speech.pipeline.failed", payload: [
            "error": message,
            "lastMethod": lastRecognitionMethod.rawValue,
            "onDeviceSupported": String(supportsOnDevice),
            "localFallback": localFallbackStatus.rawValue
        ])
        return nil
    }

    private func resetStatusesForNewPipeline() {
        setStageStatus(.notRun, for: .liveAudioBuffer)
        setStageStatus(.notRun, for: .replayAudioBuffer)
        setStageStatus(supportsOnDevice ? .notRun : .unsupported, for: .onDeviceAudioBuffer)
        localFallbackStatus = .notInstalled
        UserDefaults.standard.set(SpeechStageStatus.notInstalled.rawValue, forKey: StatusKeys.local)
        setFinalStatus(.running)
        lastErrorDomain = ""
        lastErrorCode = ""
        lastErrorDescription = ""
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: StatusKeys.errorDomain)
        defaults.removeObject(forKey: StatusKeys.errorCode)
        defaults.removeObject(forKey: StatusKeys.errorDescription)
    }

    private func setStageStatus(_ status: SpeechStageStatus, for method: SpeechRecognitionMethod) {
        let defaults = UserDefaults.standard
        switch method {
        case .liveAudioBuffer:
            liveStatus = status
            defaults.set(status.rawValue, forKey: StatusKeys.live)
        case .replayAudioBuffer:
            replayStatus = status
            defaults.set(status.rawValue, forKey: StatusKeys.replay)
        case .onDeviceAudioBuffer:
            onDeviceStatus = status
            defaults.set(status.rawValue, forKey: StatusKeys.onDevice)
        }
    }

    private func setFinalStatus(_ status: SpeechStageStatus) {
        finalStatus = status
        UserDefaults.standard.set(status.rawValue, forKey: StatusKeys.final)
    }

    private func rememberError(_ error: NSError) {
        lastErrorDomain = error.domain
        lastErrorCode = String(error.code)
        lastErrorDescription = error.localizedDescription
        let defaults = UserDefaults.standard
        defaults.set(lastErrorDomain, forKey: StatusKeys.errorDomain)
        defaults.set(lastErrorCode, forKey: StatusKeys.errorCode)
        defaults.set(lastErrorDescription, forKey: StatusKeys.errorDescription)
    }
}
