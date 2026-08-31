import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject private var repository: TransactionRepository
    @Environment(\.dismiss) private var dismiss

    init(model: AppViewModel) {
        self.model = model
        _repository = ObservedObject(wrappedValue: model.repository)
    }

    var body: some View {
        NavigationView {
            List(repository.transactions, id: \.transactionID) { item in
                NavigationLink {
                    TransactionEditView(model: model, item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.customerName ?? "Không rõ khách").font(.headline)
                            Spacer()
                            Text(item.amountVND, format: .currency(code: "VND"))
                        }
                        Text(item.product ?? "Chưa có sản phẩm")
                            .foregroundColor(.secondary)
                        HStack {
                            Text(item.paymentAt ?? item.createdAt, style: .date)
                            Spacer()
                            if item.syncStatus == SyncStatus.pending.rawValue || item.syncStatus == SyncStatus.failed.rawValue {
                                Text("Chờ đồng bộ")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("Lịch sử")
            .toolbar { Button("Đóng") { dismiss() } }
            .onAppear { repository.reload() }
        }
    }
}
