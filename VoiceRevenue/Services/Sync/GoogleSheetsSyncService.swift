import CoreData
import Foundation

struct SheetTransactionPayload: Codable {
    let transaction_id: String
    let payment_at: String?
    let amount_vnd: Int64
    let customer_name: String?
    let product: String?
    let payment_method: String
    let notes: String?
    let created_at: String
}

@MainActor
final class GoogleSheetsSyncService: ObservableObject {
    enum ConnectionStatus: Equatable {
        case notConfigured
        case testing
        case connected
        case failed

        var displayName: String {
            switch self {
            case .notConfigured: return "Chưa cấu hình"
            case .testing: return "Đang kiểm tra…"
            case .connected: return "Đã kết nối ✓"
            case .failed: return "Kết nối lỗi"
            }
        }
    }

    @Published var webAppURLString: String {
        didSet {
            UserDefaults.standard.set(webAppURLString, forKey: "appsScriptURL")
            connectionStatus = .notConfigured
            lastError = nil
        }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var connectionStatus: ConnectionStatus = .notConfigured

    weak var diagnostics: DiagnosticLogger?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        webAppURLString = UserDefaults.standard.string(forKey: "appsScriptURL") ?? ""
    }

    var isConfigured: Bool { (try? validatedURL()) != nil }

    func testConnection() async -> Bool {
        let url: URL
        do {
            url = try validatedURL()
        } catch {
            lastError = error.localizedDescription
            connectionStatus = .notConfigured
            diagnostics?.log(event: "sync.ping.validation_error", payload: ["error": error.localizedDescription])
            return false
        }

        connectionStatus = .testing
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "ping"])

            diagnostics?.log(event: "sync.ping.request", payload: safeEndpointPayload(url))
            let (data, response) = try await session.data(for: request)
            let object = try validatedJSONObject(data: data, response: response)

            guard object["ok"] as? Bool == true,
                  object["pong"] as? Bool == true,
                  object["service"] as? String == "VoiceRevenue",
                  object["sheet_access"] as? Bool == true else {
                throw SyncError.remote(String(describing: object["error"] ?? "Endpoint không trả health response VoiceRevenue hợp lệ."))
            }

            lastError = nil
            connectionStatus = .connected
            diagnostics?.log(event: "sync.ping.success", payload: [
                "serviceVersion": object["version"] as? String ?? "unknown",
                "sheetAccess": "true"
            ])
            return true
        } catch {
            lastError = error.localizedDescription
            connectionStatus = .failed
            diagnostics?.log(event: "sync.ping.error", payload: ["error": error.localizedDescription])
            return false
        }
    }

    func sync(_ item: TransactionEntity, context: NSManagedObjectContext) async -> Bool {
        do {
            let url = try validatedURL()
            item.syncStatus = SyncStatus.syncing.rawValue
            try? context.save()

            let formatter = ISO8601DateFormatter()
            let payload = SheetTransactionPayload(
                transaction_id: item.transactionID.uuidString,
                payment_at: item.paymentAt.map(formatter.string(from:)),
                amount_vnd: item.amountVND,
                customer_name: item.customerName,
                product: item.product,
                payment_method: item.paymentMethod,
                notes: item.notes,
                created_at: formatter.string(from: item.createdAt)
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            diagnostics?.log(event: "sync.transaction.request", payload: [
                "transactionID": item.transactionID.uuidString,
                "endpointHost": url.host ?? "unknown",
                "endpointPath": url.path
            ])

            let (data, response) = try await session.data(for: request)
            let object = try validatedJSONObject(data: data, response: response)
            guard object["ok"] as? Bool == true else {
                throw SyncError.remote(String(describing: object["error"] ?? "Unknown"))
            }

            item.syncStatus = SyncStatus.synced.rawValue
            try context.save()
            lastError = nil
            connectionStatus = .connected
            diagnostics?.log(event: "sync.transaction.success", payload: [
                "transactionID": item.transactionID.uuidString,
                "action": object["action"] as? String ?? "unknown"
            ])
            return true
        } catch {
            item.syncStatus = isConfigured ? SyncStatus.failed.rawValue : SyncStatus.notConfigured.rawValue
            try? context.save()
            lastError = error.localizedDescription
            diagnostics?.log(event: "sync.transaction.error", payload: [
                "transactionID": item.transactionID.uuidString,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    private func validatedURL() throws -> URL {
        let trimmed = webAppURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            throw SyncError.invalidURL("URL Apps Script phải là HTTPS.")
        }
        guard url.host?.lowercased() == "script.google.com" else {
            throw SyncError.invalidURL("Hãy dán URL Web App chính thức từ script.google.com.")
        }
        if url.path.hasSuffix("/dev") {
            throw SyncError.invalidURL("URL /dev chỉ dùng để test trong Apps Script. Hãy dùng deployment URL kết thúc bằng /exec.")
        }
        guard url.path.hasSuffix("/exec") else {
            throw SyncError.invalidURL("URL Web App phải kết thúc bằng /exec.")
        }
        return url
    }

    private func validatedJSONObject(data: Data, response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }
        let excerpt = String(data: data.prefix(400), encoding: .utf8) ?? ""
        guard 200..<300 ~= http.statusCode else {
            throw SyncError.http(http.statusCode, excerpt)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if excerpt.lowercased().contains("sign in") || excerpt.lowercased().contains("accounts.google") {
                throw SyncError.nonJSON("Endpoint yêu cầu đăng nhập Google. Deploy Web App để app có thể truy cập mà không cần OAuth.")
            }
            throw SyncError.nonJSON("Apps Script không trả JSON. Response: \(excerpt.prefix(180))")
        }
        return object
    }

    private func safeEndpointPayload(_ url: URL) -> [String: String] {
        ["endpointHost": url.host ?? "unknown", "endpointPath": url.path]
    }
}

enum SyncError: LocalizedError {
    case invalidURL(String)
    case badResponse
    case http(Int, String)
    case nonJSON(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message): return message
        case .badResponse: return "Phản hồi đồng bộ không hợp lệ."
        case .http(let code, let body):
            let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanBody.isEmpty ? "Apps Script trả HTTP \(code)." : "Apps Script trả HTTP \(code): \(cleanBody.prefix(180))"
        case .nonJSON(let message): return message
        case .remote(let message): return message
        }
    }
}
