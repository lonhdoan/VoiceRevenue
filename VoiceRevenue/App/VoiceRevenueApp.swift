import SwiftUI
import CoreData

@main
struct VoiceRevenueApp: App {
    private let persistence = PersistenceController.shared
    var body: some Scene {
        WindowGroup {
            RootView(context: persistence.container.viewContext)
        }
    }
}

private struct RootView: View {
    @StateObject private var model: AppViewModel

    init(context: NSManagedObjectContext) {
        _model = StateObject(wrappedValue: AppViewModel(context: context))
    }

    var body: some View {
        Group {
            switch model.flow {
            case .home: HomeView(model: model, repository: model.repository)
            case .recording: RecordingView(model: model)
            case .transcript: TranscriptView(model: model)
            case .review: ReviewView(model: model)
            }
        }
        .alert("Thông báo", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }
}
