import SwiftUI

struct HistoryView: View {
    @ObservedObject var repository: TransactionRepository
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List(repository.transactions) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.customerName ?? "Không rõ khách").font(.headline)
                        Spacer()
                        Text(item.amountVND, format: .currency(code: "VND"))
                    }
                    Text(item.product ?? "Chưa có sản phẩm").foregroundColor(.secondary)
                    Text(item.paymentAt ?? item.createdAt, style: .date).font(.caption)
                }
            }
            .navigationTitle("Lịch sử")
            .toolbar { Button("Đóng") { dismiss() } }
            .onAppear { repository.reload() }
        }
    }
}
