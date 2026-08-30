import CoreData
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum Flow { case home, recording, transcript, review }

    @Published var flow: Flow = .home
    @Published var transcript: String = ""
    @Published var candidates: [CandidateTransaction] = []
    @Published var alertMessage: String?

    let recorder = AudioRecorder()
    let speech = SpeechRecognizerService()
    let repository: TransactionRepository
    let sync = GoogleSheetsSyncService()
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        self.repository = TransactionRepository(context: context)
    }

    func startRecording() async {
        await recorder.start()
        if case .recording = recorder.state { flow = .recording }
    }

    func stopAndTranscribe() async {
        recorder.stop()
        guard case .recorded(let url) = recorder.state else { return }
        if let text = await speech.transcribe(url: url) {
            transcript = text
        } else {
            transcript = ""
            alertMessage = "Không nhận dạng được giọng nói. Bạn có thể nhập transcript thủ công."
        }
        flow = .transcript
    }

    func cancelRecording() {
        recorder.cancel(); flow = .home
    }

    func parseTranscript() {
        candidates = TransactionParser.parse(transcript)
        if candidates.isEmpty { candidates = [CandidateTransaction(needsReview: true, sourceText: transcript)] }
        flow = .review
    }

    func confirmCandidates() {
        do {
            for candidate in candidates { try repository.save(candidate, transcript: transcript) }
            candidates = []
            transcript = ""
            flow = .home
            Task { await syncPendingIfConfigured() }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func syncPendingIfConfigured() async {
        guard sync.isConfigured else { return }
        repository.reload()
        for item in repository.transactions where item.syncStatus != SyncStatus.synced.rawValue {
            if item.syncStatus == SyncStatus.notConfigured.rawValue { item.syncStatus = SyncStatus.pending.rawValue; try? context.save() }
            _ = await sync.sync(item, context: context)
        }
        repository.reload()
    }
}
