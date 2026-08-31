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
                Section("Nhận dạng giọng nói") {
                    HStack {
                        Text("vi-VN khả dụng")
                        Spacer()
                        Text(speech.isAvailable ? "Có" : "Không")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("On-device fallback")
                        Spacer()
                        Text(speech.supportsOnDevice ? "Có" : "Không")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Chế độ")
                        Spacer()
                        Text("Live buffer → replay buffer → on-device")
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                    }
                    Text("v0.1.4 nhận dạng trực tiếp từ microphone bằng SFSpeechAudioBufferRecognitionRequest. Nếu live không có chữ, app replay chính file audio đã lưu; on-device chỉ chạy khi iPhone báo hỗ trợ.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Lần nhận diện gần nhất") {
                    speechStatusRow("Live Apple", speech.liveStatus)
                    speechStatusRow("Replay Apple", speech.replayStatus)
                    speechStatusRow("On-device Apple", speech.onDeviceStatus)
                    speechStatusRow("Local fallback", speech.localFallbackStatus)
                    speechStatusRow("Kết quả cuối", speech.finalStatus)

                    if !speech.lastErrorDescription.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lỗi gần nhất")
                                .font(.subheadline.bold())
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

                    Text("Từ điển bổ sung")
                        .font(.subheadline)
                    Text("Mỗi dòng một tên mặt hàng thường nói ngắn gọn. Danh mục 1.000+ sản phẩm được dùng local; chỉ shortlist tối đa 100 cụm được gửi cho Apple Speech.")
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
                        Text(sync.connectionStatus.displayName)
                            .foregroundColor(statusColor)
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
                    Text("Log và audio nằm trên máy, không tự upload. Export Debug Log gộp tối đa 5 session gần nhất để lỗi Speech không biến mất sau khi app mở lại.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button(model.isProcessingRecording ? "Đang test…" : "Test nhận diện file gần nhất") {
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

                    Button("Xóa Diagnostic Logs", role: .destructive) {
                        model.diagnostics.clearLogs()
                    }
                }

                Section("Quyền riêng tư") {
                    Text("Không quảng cáo, không tracking, không telemetry. Audio được lưu local; Apple Speech có thể dùng dịch vụ Apple khi online. Giao dịch chỉ được gửi tới Apps Script do bạn tự cấu hình nếu bật đồng bộ.")
                }
            }
            .navigationTitle("Cài đặt")
            .toolbar {
                Button("Đóng") { dismiss() }
            }
            .sheet(item: $shareFile) { item in
                ActivityView(activityItems: [item.url])
            }
        }
    }

    @ViewBuilder
    private func speechStatusRow(_ label: String, _ status: SpeechStageStatus) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(status.displayName)
                .foregroundColor(speechStatusColor(status))
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

    private var statusColor: Color {
        switch sync.connectionStatus {
        case .connected: return .green
        case .failed: return .red
        case .testing: return .orange
        case .notConfigured: return .secondary
        }
    }
}
