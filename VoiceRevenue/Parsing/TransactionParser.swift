import Foundation

private struct ProductExtractionResult {
    let product: String?
    let originalProductText: String?
    let matchKind: ProductMatchKind?
    let matchScore: Double?
    let needsReview: Bool
    let evidence: [ProductMatchEvidence]
    let rejected: [RejectedProductCandidate]
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
            productMatchScore: productResult.matchScore,
            productMatches: productResult.evidence,
            rejectedProductCandidates: productResult.rejected
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
        guard let raw = rawProductCandidate(in: input, money: money, time: time), !raw.isEmpty else {
            return ProductExtractionResult(
                product: nil,
                originalProductText: nil,
                matchKind: nil,
                matchScore: nil,
                needsReview: false,
                evidence: [],
                rejected: []
            )
        }

        let matchResult = ProductCatalogMatcher.matchProductsWithTrace(
            in: raw,
            vocabulary: vocabulary,
            corrections: corrections
        )
        let evidence = matchResult.accepted

        guard !evidence.isEmpty else {
            return ProductExtractionResult(
                product: raw,
                originalProductText: raw,
                matchKind: .raw,
                matchScore: nil,
                needsReview: true,
                evidence: [
                    ProductMatchEvidence(
                        sourcePhrase: raw,
                        canonicalProduct: raw,
                        matchKind: .raw,
                        score: nil,
                        tokenStart: 0,
                        tokenCount: ProductCatalogMatcher.tokens(in: raw).count,
                        requiresReview: true
                    )
                ],
                rejected: matchResult.rejected
            )
        }

        var seen = Set<String>()
        let displayValues = evidence.compactMap { match -> String? in
            let key = VietnameseTextNormalizer.normalize(match.canonicalProduct)
            guard seen.insert(key).inserted else { return nil }
            return match.canonicalProduct
        }

        let fuzzy = evidence.first(where: { $0.matchKind == .fuzzySuggestion })
        let aggregateKind: ProductMatchKind?
        if fuzzy != nil {
            aggregateKind = .fuzzySuggestion
        } else if evidence.contains(where: { $0.matchKind == .learnedCorrection }) {
            aggregateKind = .learnedCorrection
        } else if evidence.contains(where: { $0.matchKind == .vocabularyExact }) {
            aggregateKind = .vocabularyExact
        } else {
            aggregateKind = .raw
        }

        return ProductExtractionResult(
            product: displayValues.isEmpty ? raw : displayValues.joined(separator: "\n"),
            originalProductText: fuzzy?.sourcePhrase ?? raw,
            matchKind: aggregateKind,
            matchScore: fuzzy?.score,
            needsReview: evidence.contains(where: { $0.requiresReview }),
            evidence: evidence,
            rejected: matchResult.rejected
        )
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
        return candidate
    }

    private static func replacingInsensitive(_ needle: String, in input: String, with replacement: String) -> String {
        var output = input
        while let range = output.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
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
        transcript
    }
}
