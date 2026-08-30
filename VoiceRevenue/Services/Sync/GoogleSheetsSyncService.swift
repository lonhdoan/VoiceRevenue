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
    @Published var webAppURLString: String {
        didSet { UserDefaults.standard.set(webAppURLString, forKey: "appsScriptURL") }
    }
    @Published private(set) var lastError: String?

    init() {
        webAppURLString = UserDefaults.standard.string(forKey: "appsScriptURL") ?? ""
    }

    var isConfigured: Bool { URL(string: webAppURLString)?.scheme == "https" }

    func testConnection() async -> Bool {
        guard let url = URL(string: webAppURLString), url.scheme == "https" else {
            lastError = "URL Apps Script không hợp lệ."
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "ping"])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                lastError = "Apps Script trả về HTTP lỗi."
                return false
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func sync(_ item: TransactionEntity, context: NSManagedObjectContext) async -> Bool {
        guard let url = URL(string: webAppURLString), url.scheme == "https" else {
            item.syncStatus = SyncStatus.notConfigured.rawValue
            try? context.save()
            return false
        }
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
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw SyncError.badResponse }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == false {
                throw SyncError.remote(String(describing: object["error"] ?? "Unknown"))
            }
            item.syncStatus = SyncStatus.synced.rawValue
            try context.save()
            lastError = nil
            return true
        } catch {
            item.syncStatus = SyncStatus.failed.rawValue
            try? context.save()
            lastError = error.localizedDescription
            return false
        }
    }
}

enum SyncError: LocalizedError {
    case badResponse
    case remote(String)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "Phản hồi đồng bộ không hợp lệ."
        case .remote(let message): return message
        }
    }
}
