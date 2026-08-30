import SwiftUI

struct TranscriptView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kiểm tra transcript trước khi phân tích.").font(.footnote).foregroundColor(.secondary)
                TextEditor(text: $model.transcript).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                Button("Phân tích giao dịch") { model.parseTranscript() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }.padding().navigationTitle("Transcript")
        }
    }
}
