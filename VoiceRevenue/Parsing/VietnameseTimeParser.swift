import Foundation

struct TimeParseResult: Equatable {
    let hour: Int
    let minute: Int
    let isAmbiguous: Bool
    let matchedText: String

    func date(on base: Date = Date(), calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)
    }
}

enum VietnameseTimeParser {
    static func firstTime(in input: String) -> TimeParseResult? {
        let text = VietnameseTextNormalizer.normalize(input)
        let patterns = [
            #"\b(\d{1,2})[:h](\d{2})\b"#,
            #"\b(\d{1,2})\s*gio\s*(\d{1,2})\b"#,
            #"\b(\d{1,2})\s*(?:gio\s*)?ruoi\s*(sang|toi)?\b"#,
            #"\b(?:luc\s+|khoang\s+)?(\d{1,2})\s*gio\s*(sang|toi)?\b"#,
            #"\b(?:luc\s+|khoang\s+)(\d{1,2})(?!\d)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let groups = captures(text, match)
            let matched = substring(text, match.range)

            if pattern.contains("[:h]") || pattern.contains("gio\\s*(\\d{1,2})") {
                guard groups.count >= 2,
                      let hRaw = groups[0], let mRaw = groups[1],
                      let h = Int(hRaw), let m = Int(mRaw),
                      (0...23).contains(h), (0...59).contains(m) else { continue }
                return TimeParseResult(hour: h, minute: m, isAmbiguous: h < 12, matchedText: matched)
            }

            if pattern.contains("ruoi") {
                guard let hRaw = groups.first ?? nil, var h = Int(hRaw), (0...23).contains(h) else { continue }
                let period = groups.count > 1 ? groups[1] : nil
                let ambiguous = period == nil && h < 12
                if period == "toi" && h < 12 { h += 12 }
                if period == "sang" && h == 12 { h = 0 }
                return TimeParseResult(hour: h, minute: 30, isAmbiguous: ambiguous, matchedText: matched)
            }

            guard let hRaw = groups.first ?? nil, var h = Int(hRaw), (0...23).contains(h) else { continue }
            let period = groups.count > 1 ? groups[1] : nil
            let ambiguous = period == nil && h < 12
            if period == "toi" && h < 12 { h += 12 }
            if period == "sang" && h == 12 { h = 0 }
            return TimeParseResult(hour: h, minute: 0, isAmbiguous: ambiguous, matchedText: matched)
        }
        return nil
    }

    private static func captures(_ text: String, _ match: NSTextCheckingResult) -> [String?] {
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
