import SwiftUI

struct TranscriptView: View {
    @ObservedObject var model: AppViewModel
    @FocusState private var transcriptFocused: Bool

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = model.speechFailureMessage {
                    Label("Không thể nhận diện giọng nói", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.headline)

                    Text(failure)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    HStack {
                        Button(model.isProcessingRecording ? "Đang thử lại…" : "Thử nhận diện lại") {
                            Task { await model.retryTranscription() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProcessingRecording)

                        Button("Nhập nội dung thủ công") {
                            transcriptFocused = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isProcessingRecording)
                    }
                } else {
                    Text("Kiểm tra transcript trước khi phân tích.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                TextEditor(text: $model.transcript)
                    .focused($transcriptFocused)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3))
                    )

                Button("Phân tích giao dịch") {
                    model.parseTranscript()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(
                    model.isProcessingRecording
                    || model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding()
            .navigationTitle("Transcript")
        }
    }
}
