import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var connectionMessage = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Speech") {
                    HStack { Text("vi-VN khả dụng"); Spacer(); Text(model.speech.isAvailable ? "Có" : "Không").foregroundColor(.secondary) }
                    HStack { Text("On-device"); Spacer(); Text(model.speech.supportsOnDevice ? "Có" : "Không").foregroundColor(.secondary) }
                }
                Section("Google Sheets (tùy chọn)") {
                    TextField("Apps Script Web App URL", text: $model.sync.webAppURLString)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    Button("Kiểm tra kết nối") {
                        Task { connectionMessage = await model.sync.testConnection() ? "Kết nối thành công" : (model.sync.lastError ?? "Kết nối thất bại") }
                    }
                    Button("Thử đồng bộ lại") { Task { await model.syncPendingIfConfigured() } }
                    if !connectionMessage.isEmpty { Text(connectionMessage).font(.footnote) }
                }
                Section("Quyền riêng tư") {
                    Text("Không quảng cáo, không tracking, không telemetry. Dữ liệu giao dịch nằm trên thiết bị và chỉ gửi tới Apps Script do bạn cấu hình nếu bật đồng bộ.")
                }
            }
            .navigationTitle("Cài đặt")
            .toolbar { Button("Đóng") { dismiss() } }
        }
    }
}
