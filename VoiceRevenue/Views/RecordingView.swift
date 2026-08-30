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
            Image(systemName: "waveform.circle.fill").font(.system(size: 90)).foregroundColor(.red)
            Text(recorder.elapsed.formatted(.number.precision(.fractionLength(1))) + " s").font(.title.monospacedDigit())
            Text("Đang ghi…").font(.headline)
            Spacer()
            HStack(spacing: 16) {
                Button("Hủy") { model.cancelRecording() }.buttonStyle(.bordered)
                Button("Dừng") { Task { await model.stopAndTranscribe() } }.buttonStyle(.borderedProminent)
            }
        }.padding()
    }
}
