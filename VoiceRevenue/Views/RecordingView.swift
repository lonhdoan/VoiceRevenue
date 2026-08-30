import SwiftUI

struct RecordingView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var recorder: AudioRecorder

    init(model: AppViewModel) {
        self.model = model
        self.recorder = model.recorder
    }

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 90))
                .foregroundColor(.red)

            Text(recorder.elapsed.formatted(.number.precision(.fractionLength(1))) + " s")
                .font(.title.monospacedDigit())

            Text(model.isProcessingRecording ? "Đang xử lý…" : "Đang ghi…")
                .font(.headline)

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
