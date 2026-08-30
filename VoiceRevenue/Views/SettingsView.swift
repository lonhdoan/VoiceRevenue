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
    @Environment(\.dismiss) private var dismiss
    @State private var connectionMessage = ""
    @State private var shareFile: ShareFile?

    init(model: AppViewModel) {
        self.model = model
        _vocabulary = ObservedObject(wrappedValue: model.vocabulary)
        _sync = ObservedObject(wrappedValue: model.sync)
        _repository = ObservedObject(wrappedValue: model.repository)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Nhận dạng giọng nói") {
                    HStack {
                        Text("vi-VN khả dụng")
                        Spacer()
                        Text(model.speech.isAvailable ? "Có" : "Không")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("On-device fallback")
                        Spacer()
                        Text(model.speech.supportsOnDevice ? "Có" : "Không")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Chế độ")
                        Spacer()
                        Text("Online 2-pass · ưu tiên chính xác")
                            .foregroundColor(.secondary)
                    }
                    Text("Khi có mạng, app nhận dạng lần 1 rồi dùng danh mục cửa hàng để tạo shortlist có bằng chứng và thử lại cùng file audio. Nếu online thất bại, app dùng vi-VN on-device khi thiết bị hỗ trợ.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
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
                    Text("Mỗi dòng một tên mặt hàng thường nói ngắn gọn. Danh mục 1.000+ sản phẩm được dùng local; chỉ shortlist tối đa 100 cụm liên quan mới được gửi cho Apple Speech.")
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

                    Text("Nếu URL trống/không hợp lệ, trạng thái là Chưa cấu hình. Chỉ lỗi mạng/server sau một request thật mới hiện Kết nối lỗi.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Diagnostics") {
                    Text("Log và audio nằm trên máy, không tự upload. File có thể chứa transcript, tên khách, sản phẩm và số tiền; chỉ chia sẻ khi bạn chủ động chọn.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

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
                    Text("Không quảng cáo, không tracking, không telemetry. Audio được ghi local; Apple Speech có thể dùng dịch vụ Apple khi online. Giao dịch chỉ được gửi tới Apps Script do bạn tự cấu hình nếu bật đồng bộ.")
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

    private var statusColor: Color {
        switch sync.connectionStatus {
        case .connected: return .green
        case .failed: return .red
        case .testing: return .orange
        case .notConfigured: return .secondary
        }
    }
}
