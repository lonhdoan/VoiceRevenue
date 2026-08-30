import Foundation

private struct ProductExtractionResult {
    let product: String?
    let originalProductText: String?
    let matchKind: ProductMatchKind?
    let matchScore: Double?
    let needsReview: Bool
}

private struct LocatedProductMatch {
    let location: Int
    let display: String
    let kind: ProductMatchKind
    let score: Double
    let observed: String?
    let needsReview: Bool
}

enum TransactionParser {
    private static let honorificPattern = #"\b(anh|chị|chi|cô|co|chú|chu|bạn|ban)\s+([\p{L}]+)"#
    private static let correctionMarkers = ["à không", "không phải", "sửa lại", "nhầm", "ý tôi là", "thực ra"]

    static func parse(
        _ transcript: String,
        baseDate: Date = Date(),
        vocabulary: [String] = [],
        corrections: [String: String] = [:]
    ) -> [CandidateTransaction] {
        let segments = TransactionSegmenter.segments(from: transcript)
        let candidates = segments.compactMap {
            parseSegment($0, baseDate: baseDate, vocabulary: vocabulary, corrections: corrections)
        }
        return candidates.isEmpty
            ? [parseSegment(transcript, baseDate: baseDate, vocabulary: vocabulary, corrections: corrections)].compactMap { $0 }
            : candidates
    }

    private static func parseSegment(
        _ source: String,
        baseDate: Date,
        vocabulary: [String],
        corrections: [String: String]
    ) -> CandidateTransaction? {
        let normalized = VietnameseTextNormalizer.normalize(source)
        let money = effectiveAmount(in: source)
        let time = VietnameseTimeParser.firstTime(in: source)
        let customer = extractCustomer(from: source)
        let paymentMethod = extractPaymentMethod(from: normalized)
        let productResult = extractProduct(
            from: source,
            money: money,
            time: time,
            vocabulary: vocabulary,
            corrections: corrections
        )

        if money == nil && customer == nil && productResult.product == nil { return nil }

        var paymentAt: Date?
        if let time { paymentAt = time.date(on: baseDate) }

        let needsReview = money == nil
            || customer == nil
            || productResult.product == nil
            || (time?.isAmbiguous ?? false)
            || productResult.needsReview

        return CandidateTransaction(
            paymentAt: paymentAt,
            amountVND: money?.value,
            customerName: customer,
            product: productResult.product,
            paymentMethod: paymentMethod,
            needsReview: needsReview,
            sourceText: source.trimmingCharacters(in: .whitespacesAndNewlines),
            originalProductText: productResult.originalProductText,
            productMatchKind: productResult.matchKind,
            productMatchScore: productResult.matchScore
        )
    }

    static func extractCustomer(from input: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: honorificPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges >= 3,
              let range = Range(match.range(at: 2), in: input) else { return nil }
        return String(input[range]).trimmingCharacters(in: .punctuationCharacters)
    }

    static func extractPaymentMethod(from normalized: String) -> PaymentMethod {
        if normalized.contains("chuyen khoan") || normalized.contains("bank transfer") { return .bankTransfer }
        if normalized.contains("tien mat") || normalized.contains("cash") { return .cash }
        return .unknown
    }

    static func extractProduct(
        from input: String,
        normalized: String? = nil,
        customer: String? = nil
    ) -> String? {
        // Kept for compatibility with v0.1 tests/callers. v0.1.1 uses the richer overload internally.
        let money = effectiveAmount(in: input)
        let time = VietnameseTimeParser.firstTime(in: input)
        return extractProduct(from: input, money: money, time: time, vocabulary: [], corrections: [:]).product
    }

    private static func effectiveAmount(in source: String) -> MoneyParseResult? {
        if let markerRange = firstCorrectionMarkerRange(in: source) {
            let suffix = String(source[markerRange.upperBound...])
            if let corrected = VietnameseMoneyParser.firstAmount(in: suffix) {
                return corrected
            }
        }
        return VietnameseMoneyParser.firstAmount(in: source)
    }

    private static func extractProduct(
        from input: String,
        money: MoneyParseResult?,
        time: TimeParseResult?,
        vocabulary: [String],
        corrections: [String: String]
    ) -> ProductExtractionResult {
        let canonicalVocabulary = VietnameseTextNormalizer.normalizedVocabulary(vocabulary)
        let normalizedInput = VietnameseTextNormalizer.normalize(input)
        var located: [LocatedProductMatch] = []
        var residual = normalizedInput

        // 1) Explicit learned corrections are deterministic and may auto-apply.
        for (observedRaw, canonicalRaw) in corrections {
            let observed = VietnameseTextNormalizer.normalize(observedRaw)
            let canonical = canonicalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !observed.isEmpty, !canonical.isEmpty,
                  let range = residual.range(of: observed) else { continue }
            let location = residual.distance(from: residual.startIndex, to: range.lowerBound)
            located.append(
                LocatedProductMatch(
                    location: location,
                    display: canonical,
                    kind: .learnedCorrection,
                    score: 1.0,
                    observed: observedRaw,
                    needsReview: false
                )
            )
            residual.replaceSubrange(range, with: String(repeating: " ", count: max(1, observed.count)))
        }

        // 2) Exact vocabulary matches preserve canonical Vietnamese spelling and optional quantity/unit from raw text.
        for item in canonicalVocabulary {
            let normalizedItem = VietnameseTextNormalizer.normalize(item)
            guard !normalizedItem.isEmpty, let range = residual.range(of: normalizedItem) else { continue }
            let location = residual.distance(from: residual.startIndex, to: range.lowerBound)
            let display = displayValueForExactVocabulary(item, in: input)
            located.append(
                LocatedProductMatch(
                    location: location,
                    display: display,
                    kind: .vocabularyExact,
                    score: 1.0,
                    observed: nil,
                    needsReview: false
                )
            )
            residual.replaceSubrange(range, with: String(repeating: " ", count: max(1, normalizedItem.count)))
        }

        // 3) One conservative fuzzy suggestion from the unmatched residual.
        let unmatchedVocabulary = canonicalVocabulary.filter { item in
            !located.contains { VietnameseTextNormalizer.normalize($0.display).hasPrefix(VietnameseTextNormalizer.normalize(item)) }
        }
        if let fuzzy = bestFuzzyVocabularyMatch(in: residual, vocabulary: unmatchedVocabulary) {
            located.append(fuzzy)
        }

        if !located.isEmpty {
            let ordered = located.sorted { lhs, rhs in
                if lhs.location == rhs.location { return lhs.display < rhs.display }
                return lhs.location < rhs.location
            }
            var seen = Set<String>()
            let displayValues = ordered.compactMap { match -> String? in
                let key = VietnameseTextNormalizer.normalize(match.display)
                return seen.insert(key).inserted ? match.display : nil
            }
            let fuzzy = ordered.first(where: { $0.kind == .fuzzySuggestion })
            let original = fuzzy?.observed ?? rawProductCandidate(in: input, money: money, time: time)
            return ProductExtractionResult(
                product: displayValues.joined(separator: "\n"),
                originalProductText: original,
                matchKind: fuzzy != nil ? .fuzzySuggestion : ordered.first?.kind,
                matchScore: fuzzy?.score ?? ordered.map(\.score).min(),
                needsReview: ordered.contains(where: \.needsReview)
            )
        }

        // 4) Fallback heuristic. Crucially, this returns RAW Vietnamese text, never normalized output.
        let raw = rawProductCandidate(in: input, money: money, time: time)
        return ProductExtractionResult(
            product: raw,
            originalProductText: raw,
            matchKind: raw == nil ? nil : .raw,
            matchScore: nil,
            needsReview: false
        )
    }

    private static func displayValueForExactVocabulary(_ vocabularyItem: String, in rawInput: String) -> String {
        guard let phraseRange = rawInput.range(
            of: vocabularyItem,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return vocabularyItem }

        let suffix = String(rawInput[phraseRange.upperBound...])
        let quantityPattern = #"^\s+(\d+(?:[\.,]\d+)?)\s*(m|mét|met|cm|mm|cái|cai|bộ|bo|hộp|hop|cuộn|cuon)\b"#
        guard let regex = try? NSRegularExpression(pattern: quantityPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
              let matchRange = Range(match.range, in: suffix) else { return vocabularyItem }
        let quantity = String(suffix[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(vocabularyItem) \(quantity)"
    }

    private static func bestFuzzyVocabularyMatch(in normalizedInput: String, vocabulary: [String]) -> LocatedProductMatch? {
        let words = normalizedInput
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { token in
                !["anh", "chi", "co", "chu", "ban", "tra", "thanh", "toan", "tien", "cho", "cai", "gom", "bao", "gồm", "mua", "lay", "lúc", "luc", "khoang", "gio", "nghin", "ngan", "trieu", "cu", "vnd", "dong"].contains(token)
                    && Int(token) == nil
            }
        guard !words.isEmpty else { return nil }

        var best: (item: String, score: Double, phrase: String, location: Int)?
        var secondBestScore = 0.0

        for item in vocabulary {
            let normalizedItem = VietnameseTextNormalizer.normalize(item)
            let targetWords = normalizedItem.split(separator: " ").map(String.init)
            guard !targetWords.isEmpty else { continue }
            let n = targetWords.count
            guard words.count >= n else { continue }

            for start in 0...(words.count - n) {
                let phrase = words[start..<(start + n)].joined(separator: " ")
                let score = similarity(phrase, normalizedItem)
                if let current = best {
                    if score > current.score {
                        secondBestScore = current.score
                        best = (item, score, phrase, start)
                    } else if score > secondBestScore {
                        secondBestScore = score
                    }
                } else {
                    best = (item, score, phrase, start)
                }
            }
        }

        guard let best else { return nil }
        let threshold = best.item.split(separator: " ").count == 1 ? 0.78 : 0.60
        guard best.score >= threshold, best.score - secondBestScore >= 0.06 else { return nil }

        return LocatedProductMatch(
            location: best.location,
            display: best.item,
            kind: .fuzzySuggestion,
            score: best.score,
            observed: best.phrase,
            needsReview: true
        )
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }
        let distance = previous[b.count]
        return 1.0 - Double(distance) / Double(max(a.count, b.count))
    }

    private static func rawProductCandidate(
        in input: String,
        money: MoneyParseResult?,
        time: TimeParseResult?
    ) -> String? {
        var candidate = input
        if let correctionRange = firstCorrectionMarkerRange(in: candidate) {
            candidate = String(candidate[..<correctionRange.lowerBound])
        }

        if let regex = try? NSRegularExpression(pattern: honorificPattern, options: [.caseInsensitive]) {
            let range = NSRange(candidate.startIndex..., in: candidate)
            candidate = regex.stringByReplacingMatches(in: candidate, range: range, withTemplate: " ")
        }

        if let money {
            candidate = replacingInsensitive(money.matchedText, in: candidate, with: " ")
        }
        if let time {
            candidate = replacingInsensitive(time.matchedText, in: candidate, with: " ")
        }

        for phrase in ["chuyển khoản", "bank transfer", "tiền mặt", "cash"] {
            candidate = replacingInsensitive(phrase, in: candidate, with: " ")
        }

        candidate = candidate.replacingOccurrences(of: "[.!?]", with: " ", options: .regularExpression)
        candidate = candidate.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        let prefixes = [
            "lúc", "khoảng", "trả", "thanh toán", "đã trả", "mua", "lấy", "tiền cái",
            "tiền", "cho cái", "cho", "gồm", "bao gồm", "cái", "đơn hàng", "đơn", "là"
        ]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes {
                if let range = candidate.range(
                    of: prefix,
                    options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                ) {
                    candidate.removeSubrange(range)
                    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    changed = true
                }
            }
        }

        guard !candidate.isEmpty else { return nil }

        let pieces = candidate
            .replacingOccurrences(of: #"\s+(?:và|va)\s+"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: "\n")
    }

    private static func replacingInsensitive(_ needle: String, in input: String, with replacement: String) -> String {
        var output = input
        while let range = output.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    private static func firstCorrectionMarkerRange(in input: String) -> Range<String.Index>? {
        correctionMarkers.compactMap {
            input.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }.min { lhs, rhs in lhs.lowerBound < rhs.lowerBound }
    }
}

enum TransactionSegmenter {
    static func segments(from transcript: String) -> [String] {
        if let honorificSegments = splitByCustomers(transcript), honorificSegments.count > 1 {
            return honorificSegments
        }
        let normalized = VietnameseTextNormalizer.normalize(transcript)
        let hasExplicitCorrection = ["a khong", "khong phai", "sua lai", "nham", "y toi la", "thuc ra"]
            .contains { normalized.contains($0) }
        if !hasExplicitCorrection,
           let amountSegments = splitPunctuatedRepeatedAmounts(transcript),
           amountSegments.count > 1 {
            return amountSegments
        }
        return [transcript]
    }

    private static func splitByCustomers(_ transcript: String) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?=\b(?:anh|chị|chi|cô|co|chú|chu|bạn|ban)\s+\p{L}+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsRange = NSRange(transcript.startIndex..., in: transcript)
        let matches = regex.matches(in: transcript, range: nsRange)
        guard matches.count > 1 else { return nil }
        var results: [String] = []
        for index in matches.indices {
            let start = matches[index].range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.length
            let range = NSRange(location: start, length: end - start)
            if let swiftRange = Range(range, in: transcript) {
                let value = String(transcript[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !value.isEmpty { results.append(value) }
            }
        }
        return results
    }

    private static func splitPunctuatedRepeatedAmounts(_ transcript: String) -> [String]? {
        let clauses = transcript
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard clauses.count > 1 else { return nil }

        var results: [String] = []
        var current = ""
        var currentHasAmount = false

        for clause in clauses {
            let clauseHasAmount = VietnameseMoneyParser.firstAmount(in: clause) != nil
            if clauseHasAmount && currentHasAmount && !current.isEmpty {
                results.append(current)
                current = clause
                currentHasAmount = true
            } else {
                current = current.isEmpty ? clause : "\(current), \(clause)"
                currentHasAmount = currentHasAmount || clauseHasAmount
            }
        }
        if !current.isEmpty { results.append(current) }
        return results.count > 1 ? results : nil
    }
}

enum CorrectionResolver {
    static func applyBasicCorrections(_ transcript: String) -> String {
        // v0.1.1 preserves the original transcript. TransactionParser selects the amount
        // after an explicit correction marker without normalizing away Vietnamese accents.
        transcript
    }
}
