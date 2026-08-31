import Foundation

struct MoneyParseResult: Equatable {
    let value: Int64
    let matchedText: String
}

enum VietnameseMoneyParser {
    private static let unitWords: [String: Int64] = [
        "khong": 0, "mot": 1, "một": 1, "hai": 2, "ba": 3, "bon": 4, "bốn": 4,
        "nam": 5, "năm": 5, "sau": 6, "sáu": 6, "bay": 7, "bảy": 7,
        "tam": 8, "tám": 8, "chin": 9, "chín": 9, "muoi": 10, "mười": 10
    ]

    static func firstAmount(in input: String) -> MoneyParseResult? {
        let normalized = VietnameseTextNormalizer.normalize(input)

        if let result = parseMillionPhrase(normalized) { return result }
        if let result = parseExplicitDigits(normalized) { return result }
        if let result = parseThousandPhrase(normalized) { return result }
        if let result = parseColloquialHalf(normalized) { return result }
        if let result = parseVietnameseWords(normalized) { return result }
        return nil
    }

    private static func parseExplicitDigits(_ text: String) -> MoneyParseResult? {
        let patterns = [
            #"(?<!\d)(\d{1,3}(?:[\.,]\d{3})+)(?:\s*(?:vnd|dong))?"#,
            #"(?<!\d)(\d+(?:[\.,]\d+)?)\s*(k|nghin|ngan)(?!\p{L})"#,
            #"(?<!\d)(\d+(?:[\.,]\d+)?)\s*(trieu|cu)(?!\p{L})"#,
            #"(?<!\d)(\d{4,})(?!\d)"#
        ]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: text) {
                let full = substring(text, match.range)
                let groups = captureGroups(text, match)
                if pattern.contains("k|nghin|ngan") {
                    guard let raw = groups.first ?? nil, let number = parseDecimal(raw) else { continue }
                    return MoneyParseResult(value: Int64((number * 1_000).rounded()), matchedText: full)
                }
                if pattern.contains("trieu|cu") {
                    guard let raw = groups.first ?? nil, let number = parseDecimal(raw) else { continue }
                    return MoneyParseResult(value: Int64((number * 1_000_000).rounded()), matchedText: full)
                }
                let digits = full.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
                if let value = Int64(digits) { return MoneyParseResult(value: value, matchedText: full) }
            }
        }
        return nil
    }

    private static func parseMillionPhrase(_ text: String) -> MoneyParseResult? {
        // 1 trieu 2 => 1,200,000 ; 1 trieu 200 => 1,200,000 ; 1 trieu ruoi => 1,500,000
        let patterns = [
            #"(?<!\d)(\d+)\s*tr\s*(\d{1,3})(?!\d)"#,
            #"(?<!\d)(\d+)\s*(?:trieu|cu)\s*(ruoi)"#,
            #"(?<!\d)(\d+)\s*(?:trieu|cu)\s*(\d{1,3})(?!\d)"#,
            #"(?<!\d)(\d+)\s*(?:trieu|cu)(?!\p{L})"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: text) else { continue }
            let groups = captureGroups(text, match)
            guard let majorRaw = groups.first ?? nil, let major = Int64(majorRaw) else { continue }
            var value = major * 1_000_000
            if groups.count > 1, let tail = groups[1] {
                if tail == "ruoi" {
                    value += 500_000
                } else if let n = Int64(tail) {
                    if n < 10 { value += n * 100_000 }
                    else if n < 100 { value += n * 10_000 }
                    else { value += n * 1_000 }
                }
            }
            return MoneyParseResult(value: value, matchedText: substring(text, match.range))
        }

        let wordPatterns = [
            #"\b(mot|hai|ba|bon|nam|sau|bay|tam|chin)\s+(?:trieu|cu)\s+ruoi\b"#,
            #"\b(mot|hai|ba|bon|nam|sau|bay|tam|chin)\s+(?:trieu|cu)\s+(mot|hai|ba|bon|nam|sau|bay|tam|chin)\b"#,
            #"\b(mot|hai|ba|bon|nam|sau|bay|tam|chin)\s+(?:trieu|cu)\b"#
        ]
        for pattern in wordPatterns {
            guard let match = firstMatch(pattern, in: text) else { continue }
            let groups = captureGroups(text, match)
            guard let first = groups.first ?? nil, let major = unitWords[first] else { continue }
            var value = major * 1_000_000
            if groups.count > 1, let tail = groups[1], let minor = unitWords[tail] {
                value += minor * 100_000
            } else if substring(text, match.range).contains("ruoi") {
                value += 500_000
            }
            return MoneyParseResult(value: value, matchedText: substring(text, match.range))
        }
        return nil
    }

    private static func parseThousandPhrase(_ text: String) -> MoneyParseResult? {
        let pattern = #"(?<!\d)(\d+)\s*(?:nghin|ngan)(?!\p{L})"#
        guard let match = firstMatch(pattern, in: text),
              let raw = captureGroups(text, match).first ?? nil,
              let n = Int64(raw) else { return nil }
        return MoneyParseResult(value: n * 1_000, matchedText: substring(text, match.range))
    }

    private static func parseColloquialHalf(_ text: String) -> MoneyParseResult? {
        // "ba tram ruoi" in sales context means 350,000 VND.
        let pattern = #"\b(mot|hai|ba|bon|nam|sau|bay|tam|chin)\s+tram\s+ruoi\b"#
        guard let match = firstMatch(pattern, in: text),
              let raw = captureGroups(text, match).first ?? nil,
              let n = unitWords[raw] else { return nil }
        return MoneyParseResult(value: n * 100_000 + 50_000, matchedText: substring(text, match.range))
    }

    private static func parseVietnameseWords(_ text: String) -> MoneyParseResult? {
        let tokens = text.split(separator: " ").map(String.init)
        guard let thousandIndex = tokens.firstIndex(where: { $0 == "nghin" || $0 == "ngan" }) else { return nil }
        let maxStart = max(0, thousandIndex - 5)
        for start in maxStart..<thousandIndex {
            let words = Array(tokens[start..<thousandIndex])
            if let value = parseBelowThousand(words), value > 0 {
                return MoneyParseResult(value: value * 1_000, matchedText: tokens[start...thousandIndex].joined(separator: " "))
            }
        }
        return nil
    }

    private static func parseBelowThousand(_ words: [String]) -> Int64? {
        guard !words.isEmpty else { return nil }
        var total: Int64 = 0
        var index = 0

        if index + 1 < words.count, let hundreds = unitWords[words[index]], words[index + 1] == "tram", hundreds > 0 {
            total += hundreds * 100
            index += 2
        }

        if index < words.count {
            if words[index] == "muoi" {
                total += 10
                index += 1
            } else if index + 1 < words.count, let tens = unitWords[words[index]], words[index + 1] == "muoi", tens > 0 {
                total += tens * 10
                index += 2
            }
        }

        if index < words.count {
            if words[index] == "linh" || words[index] == "le" { index += 1 }
            if index < words.count, let units = unitWords[words[index]], units >= 0 {
                total += units
                index += 1
            }
        }

        return index == words.count ? total : nil
    }

    private static func parseDecimal(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func captureGroups(_ text: String, _ match: NSTextCheckingResult) -> [String?] {
        guard match.numberOfRanges > 1 else { return [] }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }
}
