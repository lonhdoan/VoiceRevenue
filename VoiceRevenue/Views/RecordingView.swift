import SwiftUI

struct RecordingView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var speech: SpeechRecognizerService

    init(model: AppViewModel) {
        self.model = model
        self.recorder = model.recorder
        self.speech = model.speech
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 90))
                .foregroundColor(.red)

            Text(recorder.elapsed.formatted(.number.precision(.fractionLength(1))) + " s")
                .font(.title.monospacedDigit())

            Text(model.isProcessingRecording ? "Đang xử lý…" : "Đang nghe…")
                .font(.headline)

            Group {
                let live = speech.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if live.isEmpty {
                    Text("Nói một câu ngắn bằng tiếng Việt. Chữ nhận được sẽ xuất hiện tại đây ngay khi Apple Speech trả kết quả.")
                        .foregroundColor(.secondary)
                } else {
                    Text(live)
                        .font(.title3)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.horizontal)

            Spacer()

            Button {
                Task { await model.stopAndTranscribe() }
            } label: {
                Label(
                    model.isProcessingRecording ? "Đang xử lý…" : "Dừng ghi âm",
                    systemImage: "stop.fill"
                )
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isProcessingRecording)

            Button("Hủy") {
                model.cancelRecording()
            }
            .buttonStyle(.bordered)
            .disabled(model.isProcessingRecording)
        }
        .padding()
    }
}
