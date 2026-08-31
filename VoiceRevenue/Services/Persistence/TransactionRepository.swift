import CoreData
import Foundation

@MainActor
final class TransactionRepository: ObservableObject {
    private let context: NSManagedObjectContext
    @Published private(set) var transactions: [TransactionEntity] = []

    init(context: NSManagedObjectContext) {
        self.context = context
        reload()
    }

    func save(_ candidate: CandidateTransaction, transcript: String) throws {
        guard let amount = candidate.amountVND else { throw RepositoryError.missingAmount }
        let item = TransactionEntity(context: context)
        item.transactionID = UUID()
        item.paymentAt = candidate.paymentAt
        item.amountVND = amount
        item.customerName = candidate.customerName
        item.product = candidate.product
        item.paymentMethod = candidate.paymentMethod.rawValue
        item.notes = candidate.notes
        item.createdAt = Date()
        item.originalTranscript = transcript
        item.needsReview = candidate.needsReview
        item.syncStatus = SyncStatus.notConfigured.rawValue
        try context.save()
        reload()
    }

    func update(
        _ item: TransactionEntity,
        amountVND: Int64,
        customerName: String?,
        product: String?,
        paymentMethod: PaymentMethod,
        paymentAt: Date?,
        notes: String?,
        markForSync: Bool
    ) throws {
        guard amountVND > 0 else { throw RepositoryError.missingAmount }
        item.amountVND = amountVND
        item.customerName = Self.nilIfBlank(customerName)
        item.product = Self.nilIfBlank(product)
        item.paymentMethod = paymentMethod.rawValue
        item.paymentAt = paymentAt
        item.notes = Self.nilIfBlank(notes)
        item.needsReview = false
        item.syncStatus = markForSync ? SyncStatus.pending.rawValue : SyncStatus.notConfigured.rawValue
        try context.save()
        reload()
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func reload() {
        let request = TransactionEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        transactions = (try? context.fetch(request)) ?? []
    }

    var todayRevenue: Int64 {
        let calendar = Calendar.current
        return transactions.filter { calendar.isDateInToday($0.paymentAt ?? $0.createdAt) }.reduce(0) { $0 + $1.amountVND }
    }

    var todayCount: Int { transactions.filter { Calendar.current.isDateInToday($0.paymentAt ?? $0.createdAt) }.count }
    var pendingSyncCount: Int { transactions.filter { $0.syncStatus == SyncStatus.pending.rawValue || $0.syncStatus == SyncStatus.failed.rawValue }.count }
}

enum RepositoryError: LocalizedError {
    case missingAmount
    var errorDescription: String? { "Giao dịch chưa có số tiền." }
}
