import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "VoiceRevenue", managedObjectModel: model)
        if inMemory { container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null") }
        container.loadPersistentStores { _, error in
            if let error { assertionFailure("Core Data store failed: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "TransactionEntity"
        entity.managedObjectClassName = NSStringFromClass(TransactionEntity.self)

        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional; a.defaultValue = defaultValue; return a
        }

        entity.properties = [
            attr("transactionID", .UUIDAttributeType),
            attr("paymentAt", .dateAttributeType, optional: true),
            attr("amountVND", .integer64AttributeType),
            attr("customerName", .stringAttributeType, optional: true),
            attr("product", .stringAttributeType, optional: true),
            attr("paymentMethod", .stringAttributeType, defaultValue: PaymentMethod.unknown.rawValue),
            attr("notes", .stringAttributeType, optional: true),
            attr("createdAt", .dateAttributeType),
            attr("originalTranscript", .stringAttributeType, defaultValue: ""),
            attr("needsReview", .booleanAttributeType, defaultValue: false),
            attr("syncStatus", .stringAttributeType, defaultValue: SyncStatus.notConfigured.rawValue),
            attr("recordingID", .UUIDAttributeType, optional: true)
        ]
        model.entities = [entity]
        return model
    }
}

@objc(TransactionEntity)
final class TransactionEntity: NSManagedObject {
    @NSManaged var transactionID: UUID
    @NSManaged var paymentAt: Date?
    @NSManaged var amountVND: Int64
    @NSManaged var customerName: String?
    @NSManaged var product: String?
    @NSManaged var paymentMethod: String
    @NSManaged var notes: String?
    @NSManaged var createdAt: Date
    @NSManaged var originalTranscript: String
    @NSManaged var needsReview: Bool
    @NSManaged var syncStatus: String
    @NSManaged var recordingID: UUID?
}

extension TransactionEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<TransactionEntity> {
        NSFetchRequest<TransactionEntity>(entityName: "TransactionEntity")
    }
}
