import SwiftUI

struct ReviewView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach($model.candidates) { $item in
                        Section {
                            TextField("Khách hàng", text: Binding($item.customerName, replacingNilWith: ""))
                            TextField("Sản phẩm", text: Binding($item.product, replacingNilWith: ""))
                            TextField("Số tiền VND", text: Binding(
                                get: { item.amountVND.map(String.init) ?? "" },
                                set: { item.amountVND = Int64($0.filter(\.isNumber)) }
                            ))
                            .keyboardType(.numberPad)
                            DatePicker("Thời gian", selection: Binding($item.paymentAt, replacingNilWith: Date()), displayedComponents: [.date, .hourAndMinute])
                            Picker("Thanh toán", selection: $item.paymentMethod) {
                                ForEach(PaymentMethod.allCases) { method in Text(method.displayName).tag(method) }
                            }
                            if item.needsReview { Label("Cần kiểm tra", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange) }
                            Text(item.sourceText).font(.caption).foregroundColor(.secondary)
                        }
                    }.onDelete { model.candidates.remove(atOffsets: $0) }
                    Button("Thêm giao dịch") { model.candidates.append(CandidateTransaction(needsReview: true, sourceText: model.transcript)) }
                }
                Button("Xác nhận giao dịch") { model.confirmCandidates() }
                    .buttonStyle(.borderedProminent).padding()
                    .disabled(model.candidates.contains { $0.amountVND == nil })
            }.navigationTitle("Kiểm tra")
        }
    }
}

private extension Binding where Value == String? {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private extension Binding where Value == Date? {
    init(_ source: Binding<Date?>, replacingNilWith fallback: Date) {
        self.init(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0 })
    }
}
