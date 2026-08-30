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
                        Text("Tự động · ưu tiên chính xác")
                            .foregroundColor(.secondary)
                    }
                    Text("Khi có mạng, app cho phép Apple Speech dùng dịch vụ online để ưu tiên độ chính xác. Nếu online thất bại và thiết bị hỗ trợ vi-VN on-device, app tự thử lại cùng file ghi âm trên thiết bị.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Từ điển mặt hàng") {
                    Text("Mỗi dòng một mặt hàng. Tối đa 100 cụm đầu tiên được gửi làm gợi ý cho Apple Speech; parser cũng dùng danh sách này để khớp tên mặt hàng.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    TextEditor(text: $vocabulary.editableText)
                        .frame(minHeight: 150)

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
                                : (sync.lastError ?? "Kết nối thất bại")
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
                            .foregroundColor(sync.lastError == nil ? .secondary : .red)
                    }

                    Text("Dùng URL deployment kết thúc bằng /exec. URL /dev chỉ dành cho Test deployment trong Apps Script.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Diagnostics") {
                    Text("Log nằm trên máy và không tự upload. File có thể chứa transcript, tên khách, sản phẩm và số tiền; chỉ chia sẻ khi bạn chủ động chọn.")
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
