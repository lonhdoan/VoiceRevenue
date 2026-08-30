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
