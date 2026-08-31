import SwiftUI
import UIKit

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject private var vocabulary: ProductVocabularyStore
    @ObservedObject private var sync: GoogleSheetsSyncService
    @ObservedObject private var repository: TransactionRepository
    @ObservedObject private var speech: SpeechRecognizerService
    @Environment(\.dismiss) private var dismiss
    @State private var connectionMessage = ""
    @State private var shareFile: ShareFile?

    init(model: AppViewModel) {
        self.model = model
        _vocabulary = ObservedObject(wrappedValue: model.vocabulary)
        _sync = ObservedObject(wrappedValue: model.sync)
        _repository = ObservedObject(wrappedValue: model.repository)
        _speech = ObservedObject(wrappedValue: model.speech)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Nhận dạng mã nguồn mở") {
                    HStack {
                        Text("Engine")
                        Spacer()
                        Text("sherpa-onnx 1.13.6")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Model tiếng Việt")
                        Spacer()
                        Text(speech.modelState.displayName)
                            .foregroundColor(modelStatusColor)
                    }
                    Text(SpeechRecognizerService.modelName)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    HStack {
                        Text("Hoạt động offline")
                        Spacer()
                        Text(speech.isAvailable ? "Có" : "Chưa sẵn sàng")
                            .foregroundColor(speech.isAvailable ? .green : .orange)
                    }
                    Text("Core STT chạy hoàn toàn trên máy bằng engine và model mã nguồn mở. Apple Speech không còn nằm trong đường nhận dạng chính.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button("Kiểm tra model offline") {
                        Task { await speech.refreshModelState() }
                    }
                }

                Section("Tăng độ chính xác bằng máy chủ riêng") {
                    Toggle("Bật tăng độ chính xác", isOn: $speech.remoteReinforcementEnabled)
                    TextField("Endpoint, ví dụ http://192.168.1.10:8000/v1/audio/transcriptions", text: $speech.remoteEndpointURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disabled(!speech.remoteReinforcementEnabled)
                    TextField("Model trên server", text: $speech.remoteModelName)
                        .textInputAutocapitalization(.never)
                        .disabled(!speech.remoteReinforcementEnabled)
                    Text("Mặc định tắt. Audio chỉ rời khỏi iPhone khi bạn bật tùy chọn này. Server riêng có thể dùng Speaches/faster-whisper; nếu server lỗi hoặc mất mạng, kết quả local vẫn được dùng.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Lần nhận diện gần nhất") {
                    speechStatusRow("Local sherpa-onnx", speech.localStatus)
                    speechStatusRow("Server riêng", speech.remoteStatus)
                    speechStatusRow("Kết quả cuối", speech.finalStatus)
                    if let seconds = speech.lastInferenceSeconds {
                        HStack {
                            Text("Thời gian local")
                            Spacer()
                            Text(String(format: "%.2f s", seconds)).foregroundColor(.secondary)
                        }
                    }
                    if let rtf = speech.lastRealtimeFactor {
                        HStack {
                            Text("Real-time factor")
                            Spacer()
                            Text(String(format: "%.2f", rtf)).foregroundColor(.secondary)
                        }
                    }
                    if !speech.lastErrorDescription.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lỗi gần nhất").font(.subheadline.bold())
                            if !speech.lastErrorDomain.isEmpty || !speech.lastErrorCode.isEmpty {
                                Text("\(speech.lastErrorDomain) · \(speech.lastErrorCode)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Text(speech.lastErrorDescription)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Danh mục mặt hàng") {
                    HStack {
                        Text("Danh mục cửa hàng")
                        Spacer()
                        Text("\(vocabulary.catalogCount) mặt hàng")
                            .foregroundColor(vocabulary.catalogCount > 0 ? .green : .red)
                    }
                    Text(vocabulary.catalogSourceFile)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Từ điển bổ sung").font(.subheadline)
                    Text("Danh mục và các sửa lỗi đã học chỉ được dùng local để đối chiếu sản phẩm sau khi có transcript thật; app không ép mọi câu nói phải khớp một sản phẩm.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TextEditor(text: $vocabulary.editableText)
                        .frame(minHeight: 130)

                    HStack {
                        Text("Đã học \(vocabulary.learnedCorrectionCount) sửa lỗi")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Xóa sửa lỗi đã học", role: .destructive) {
                            vocabulary.clearCorrections()
                        }
                        .disabled(vocabulary.learnedCorrectionCount == 0)
                    }
                }

                Section("Google Sheets (tùy chọn)") {
                    HStack {
                        Text("Trạng thái")
                        Spacer()
                        Text(sync.connectionStatus.displayName).foregroundColor(statusColor)
                    }
                    TextField("Apps Script Web App URL (.../exec)", text: $sync.webAppURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("Kiểm tra kết nối") {
                        Task {
                            let success = await sync.testConnection()
                            connectionMessage = success
                                ? "Kết nối thành công và truy cập được sheet."
                                : (sync.lastError ?? "Chưa cấu hình URL Web App hợp lệ.")
                        }
                    }
                    .disabled(sync.connectionStatus == .testing)

                    Button("Đồng bộ lại \(repository.pendingSyncCount) giao dịch") {
                        Task {
                            await model.syncPendingIfConfigured()
                            connectionMessage = sync.lastError ?? "Đã thử đồng bộ lại các giao dịch đang chờ."
                        }
                    }
                    .disabled(repository.pendingSyncCount == 0 || !sync.isConfigured)

                    if !connectionMessage.isEmpty {
                        Text(connectionMessage)
                            .font(.footnote)
                            .foregroundColor(sync.connectionStatus == .failed ? .red : .secondary)
                    }
                }

                Section("Diagnostics") {
                    Text("Log và audio nằm trên máy, không tự upload. Diagnostic ghi engine/model, thời gian inference, transcript local/remote và quyết định chọn kết quả.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button(model.isProcessingRecording ? "Đang test…" : "Test offline file gần nhất") {
                        Task { await model.testLastRecordingSpeech() }
                    }
                    .disabled(model.recorder.lastRecordingURL == nil || model.isProcessingRecording)

                    Button("Export Debug Log") {
                        model.diagnostics.log(event: "diagnostics.export.requested")
                        if let url = model.diagnostics.exportURL() {
                            shareFile = ShareFile(url: url)
                        } else {
                            model.alertMessage = "Không tìm thấy diagnostic log để export."
                        }
                    }
                    Button("Export Last Recording") {
                        if let url = model.recorder.lastRecordingURL {
                            model.diagnostics.log(event: "diagnostics.audio_export.requested", payload: ["file": url.lastPathComponent])
                            shareFile = ShareFile(url: url)
                        } else {
                            model.alertMessage = "Chưa có file ghi âm gần nhất để export."
                        }
                    }
                    .disabled(model.recorder.lastRecordingURL == nil)
                    Button("Xóa Diagnostic Logs", role: .destructive) { model.diagnostics.clearLogs() }
                }

                Section("Quyền riêng tư") {
                    Text("Không quảng cáo, tracking hay telemetry. STT local không gửi audio cho Apple hoặc cloud. Chỉ khi bạn tự bật máy chủ tăng độ chính xác thì audio mới được gửi tới endpoint do chính bạn cấu hình. Google Sheets vẫn là tùy chọn riêng.")
                }
            }
            .navigationTitle("Cài đặt")
            .toolbar { Button("Đóng") { dismiss() } }
            .sheet(item: $shareFile) { item in ActivityView(activityItems: [item.url]) }
            .task { await speech.refreshModelState() }
        }
    }

    @ViewBuilder
    private func speechStatusRow(_ label: String, _ status: SpeechStageStatus) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(status.displayName).foregroundColor(speechStatusColor(status))
        }
    }

    private func speechStatusColor(_ status: SpeechStageStatus) -> Color {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .running: return .orange
        case .unsupported, .notInstalled, .notRun: return .secondary
        }
    }

    private var modelStatusColor: Color {
        switch speech.modelState {
        case .ready: return .green
        case .verifying: return .orange
        case .missing, .invalid: return .red
        case .unknown: return .secondary
        }
    }

    private var statusColor: Color {
        switch sync.connectionStatus {
        case .connected: return .green
        case .failed: return .red
        case .testing: return .orange
        case .notConfigured: return .secondary
        }
    }
}
