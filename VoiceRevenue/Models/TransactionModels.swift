import Foundation

enum PaymentMethod: String, Codable, CaseIterable, Identifiable {
    case cash
    case bankTransfer
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: return "Tiền mặt"
        case .bankTransfer: return "Chuyển khoản"
        case .unknown: return "Không rõ"
        }
    }
}

enum SyncStatus: String, Codable {
    case notConfigured
    case pending
    case syncing
    case synced
    case failed
}

struct CandidateTransaction: Identifiable, Equatable {
    let id: UUID
    var paymentAt: Date?
    var amountVND: Int64?
    var customerName: String?
    var product: String?
    var paymentMethod: PaymentMethod
    var notes: String?
    var needsReview: Bool
    var sourceText: String

    init(
        id: UUID = UUID(),
        paymentAt: Date? = nil,
        amountVND: Int64? = nil,
        customerName: String? = nil,
        product: String? = nil,
        paymentMethod: PaymentMethod = .unknown,
        notes: String? = nil,
        needsReview: Bool = false,
        sourceText: String = ""
    ) {
        self.id = id
        self.paymentAt = paymentAt
        self.amountVND = amountVND
        self.customerName = customerName
        self.product = product
        self.paymentMethod = paymentMethod
        self.notes = notes
        self.needsReview = needsReview
        self.sourceText = sourceText
    }
}

struct StoredTransaction: Identifiable, Codable, Equatable {
    let id: UUID
    var paymentAt: Date?
    var amountVND: Int64
    var customerName: String?
    var product: String?
    var paymentMethod: PaymentMethod
    var notes: String?
    let createdAt: Date
    var originalTranscript: String
    var needsReview: Bool
    var syncStatus: SyncStatus
    var recordingID: UUID?
}
