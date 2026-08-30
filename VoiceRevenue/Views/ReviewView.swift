import SwiftUI

struct ReviewView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach($model.candidates) { $item in
                        Section {
                            TextField(
                                "Khách hàng",
                                text: Binding(
                                    $item.customerName,
                                    replacingNilWith: ""
                                )
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sản phẩm")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextEditor(
                                    text: Binding(
                                        $item.product,
                                        replacingNilWith: ""
                                    )
                                )
                                .frame(minHeight: 72)

                                if item.productMatchKind == .fuzzySuggestion {
                                    Label("Tên mặt hàng được đề xuất từ từ điển — hãy kiểm tra trước khi xác nhận.", systemImage: "sparkles")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                } else if item.productMatchKind == .learnedCorrection {
                                    Label("Đã áp dụng sửa lỗi bạn từng xác nhận.", systemImage: "checkmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }

                            TextField(
                                "Số tiền VND",
                                text: Binding(
                                    get: { item.amountVND.map(String.init) ?? "" },
                                    set: {
                                        let digits = $0.filter(\.isNumber)
                                        item.amountVND = digits.isEmpty ? nil : Int64(digits)
                                    }
                                )
                            )
                            .keyboardType(.numberPad)

                            DatePicker(
                                "Thời gian",
                                selection: Binding(
                                    $item.paymentAt,
                                    replacingNilWith: Date()
                                ),
                                displayedComponents: [.date, .hourAndMinute]
                            )

                            Picker("Thanh toán", selection: $item.paymentMethod) {
                                ForEach(PaymentMethod.allCases) { method in
                                    Text(method.displayName).tag(method)
                                }
                            }

                            if item.needsReview {
                                Label("Cần kiểm tra", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }

                            Text(item.sourceText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { model.candidates.remove(atOffsets: $0) }

                    Button("Thêm giao dịch") {
                        model.candidates.append(
                            CandidateTransaction(
                                needsReview: true,
                                sourceText: model.transcript
                            )
                        )
                    }
                }

                Button("Xác nhận giao dịch") {
                    model.confirmCandidates()
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .disabled(model.candidates.contains { $0.amountVND == nil })
            }
            .navigationTitle("Kiểm tra")
        }
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { newValue in source.wrappedValue = newValue.isEmpty ? nil : newValue }
        )
    }
}

private extension Binding where Value == Date {
    init(_ source: Binding<Date?>, replacingNilWith fallback: Date) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { newValue in source.wrappedValue = newValue }
        )
    }
}
