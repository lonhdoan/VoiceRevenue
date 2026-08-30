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

enum ProductMatchKind: String, Codable, Equatable {
    case raw
    case vocabularyExact
    case learnedCorrection
    case fuzzySuggestion
}

struct ProductMatchEvidence: Equatable {
    let sourcePhrase: String
    let canonicalProduct: String
    let matchKind: ProductMatchKind
    let score: Double?
    let tokenStart: Int
    let tokenCount: Int
    let requiresReview: Bool
}


struct RejectedProductCandidate: Equatable {
    let sourcePhrase: String
    let canonicalProduct: String
    let score: Double
    let secondBestScore: Double
    let tokenStart: Int
    let tokenCount: Int
    let reason: String
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

    // Transient v0.1.1 metadata. These values are intentionally not stored in Core Data.
    var originalProductText: String?
    var productMatchKind: ProductMatchKind?
    var productMatchScore: Double?
    var productMatches: [ProductMatchEvidence]
    var rejectedProductCandidates: [RejectedProductCandidate]

    init(
        id: UUID = UUID(),
        paymentAt: Date? = nil,
        amountVND: Int64? = nil,
        customerName: String? = nil,
        product: String? = nil,
        paymentMethod: PaymentMethod = .unknown,
        notes: String? = nil,
        needsReview: Bool = false,
        sourceText: String = "",
        originalProductText: String? = nil,
        productMatchKind: ProductMatchKind? = nil,
        productMatchScore: Double? = nil,
        productMatches: [ProductMatchEvidence] = [],
        rejectedProductCandidates: [RejectedProductCandidate] = []
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
        self.originalProductText = originalProductText
        self.productMatchKind = productMatchKind
        self.productMatchScore = productMatchScore
        self.productMatches = productMatches
        self.rejectedProductCandidates = rejectedProductCandidates
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
