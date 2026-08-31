import SwiftUI

struct TransactionEditView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var item: TransactionEntity
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    @State private var customerName: String
    @State private var product: String
    @State private var paymentMethod: PaymentMethod
    @State private var hasPaymentDate: Bool
    @State private var paymentAt: Date
    @State private var notes: String
    @State private var validationMessage: String?

    init(model: AppViewModel, item: TransactionEntity) {
        self.model = model
        self.item = item
        _amountText = State(initialValue: String(item.amountVND))
        _customerName = State(initialValue: item.customerName ?? "")
        _product = State(initialValue: item.product ?? "")
        _paymentMethod = State(initialValue: PaymentMethod(rawValue: item.paymentMethod) ?? .unknown)
        _hasPaymentDate = State(initialValue: item.paymentAt != nil)
        _paymentAt = State(initialValue: item.paymentAt ?? item.createdAt)
        _notes = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        Form {
            Section("Giao dịch") {
                TextField("Số tiền (VND)", text: $amountText)
                    .keyboardType(.numberPad)
                TextField("Khách hàng", text: $customerName)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sản phẩm")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $product)
                        .frame(minHeight: 90)
                }

                Picker("Thanh toán", selection: $paymentMethod) {
                    ForEach(PaymentMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            }

            Section("Thời gian") {
                Toggle("Có thời gian thanh toán", isOn: $hasPaymentDate)
                if hasPaymentDate {
                    DatePicker("Ngày & giờ", selection: $paymentAt)
                }
            }

            Section("Ghi chú") {
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Sửa giao dịch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Hủy") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Lưu") { save() }
                    .font(.headline)
            }
        }
    }

    private func save() {
        let digits = amountText.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        guard let amount = Int64(digits), amount > 0 else {
            validationMessage = "Số tiền phải lớn hơn 0."
            return
        }

        do {
            try model.updateTransaction(
                item,
                amountVND: amount,
                customerName: customerName,
                product: product,
                paymentMethod: paymentMethod,
                paymentAt: hasPaymentDate ? paymentAt : nil,
                notes: notes
            )
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
