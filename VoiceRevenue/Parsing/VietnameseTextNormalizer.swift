import Foundation

enum VietnameseTextNormalizer {
    static func normalize(_ input: String) -> String {
        var text = input.lowercased()
        text = text.replacingOccurrences(of: "đ", with: "d")
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
