import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var repository: TransactionRepository
    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Doanh thu hôm nay").font(.headline)
                    Text(repository.todayRevenue, format: .currency(code: "VND")).font(.system(size: 34, weight: .bold))
                    Text("\(repository.todayCount) giao dịch · \(repository.pendingSyncCount) chờ đồng bộ")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Ghi doanh thu", systemImage: "mic.fill")
                        .font(.title2.bold()).frame(maxWidth: .infinity).padding()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("Voice Revenue")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showHistory = true } label: { Image(systemName: "clock") }
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $showHistory) { HistoryView(repository: repository) }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        }
    }
}
