import Foundation

enum TransactionParser {
    private static let honorificPattern = #"\b(anh|chi|co|chu|ban)\s+([\p{L}]+)"#

    static func parse(_ transcript: String, baseDate: Date = Date()) -> [CandidateTransaction] {
        let corrected = CorrectionResolver.applyBasicCorrections(transcript)
        let segments = TransactionSegmenter.segments(from: corrected)
        let candidates = segments.compactMap { parseSegment($0, baseDate: baseDate) }
        return candidates.isEmpty ? [parseSegment(corrected, baseDate: baseDate)].compactMap { $0 } : candidates
    }

    private static func parseSegment(_ source: String, baseDate: Date) -> CandidateTransaction? {
        let normalized = VietnameseTextNormalizer.normalize(source)
        let money = VietnameseMoneyParser.firstAmount(in: source)
        let time = VietnameseTimeParser.firstTime(in: source)
        let customer = extractCustomer(from: source)
        let paymentMethod = extractPaymentMethod(from: normalized)
        let product = extractProduct(from: source, normalized: normalized, customer: customer)

        if money == nil && customer == nil && product == nil { return nil }

        var paymentAt: Date?
        if let time { paymentAt = time.date(on: baseDate) }
        let needsReview = money == nil || customer == nil || product == nil || (time?.isAmbiguous ?? false)

        return CandidateTransaction(
            paymentAt: paymentAt,
            amountVND: money?.value,
            customerName: customer,
            product: product,
            paymentMethod: paymentMethod,
            needsReview: needsReview,
            sourceText: source.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func extractProduct(from input: String, normalized: String? = nil, customer: String? = nil) -> String? {
        let text = normalized ?? VietnameseTextNormalizer.normalize(input)
        let markers = ["tien cai ", "tien ", "cho cai ", "cho "]
        for marker in markers {
            if let range = text.range(of: marker) {
                var product = String(text[range.upperBound...])
                product = product.components(separatedBy: ",").first ?? product
                product = product.components(separatedBy: ".").first ?? product
                let correctionTokens = [" a khong ", " y toi la ", " sua lai "]
                for token in correctionTokens {
                    if let correctionRange = product.range(of: token) { product = String(product[..<correctionRange.lowerBound]) }
                }
                product = product.trimmingCharacters(in: .whitespacesAndNewlines)
                if !product.isEmpty { return product }
            }
        }

        // Heuristic for common "X nghin bien neon" / "1 trieu bien C" forms.
        if let amount = VietnameseMoneyParser.firstAmount(in: input),
           let amountRange = text.range(of: VietnameseTextNormalizer.normalize(amount.matchedText)) {
            var tail = String(text[amountRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            tail = tail.replacingOccurrences(of: #"^(?:dong|vnd)\s*"#, with: "", options: .regularExpression)
            tail = tail.components(separatedBy: ",").first ?? tail
            if !tail.isEmpty { return tail }
        }
        return nil
    }
}

enum TransactionSegmenter {
    static func segments(from transcript: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?=\b(?:anh|chị|chi|cô|co|chú|chu|bạn|ban)\s+\p{L}+)"#, options: [.caseInsensitive]) else {
            return [transcript]
        }
        let nsRange = NSRange(transcript.startIndex..., in: transcript)
        let matches = regex.matches(in: transcript, range: nsRange)
        guard matches.count > 1 else { return [transcript] }

        var results: [String] = []
        for index in matches.indices {
            let start = matches[index].range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.length
            let range = NSRange(location: start, length: end - start)
            if let swiftRange = Range(range, in: transcript) {
                results.append(String(transcript[swiftRange]))
            }
        }
        return results
    }
}

enum CorrectionResolver {
    static func applyBasicCorrections(_ transcript: String) -> String {
        // Conservative handling for the most common explicit same-customer amount correction.
        // Example: "Anh Nam 350 nghìn, à không Nam 380 nghìn" -> "Anh Nam 380 nghìn".
        let normalized = VietnameseTextNormalizer.normalize(transcript)
        let pattern = #"\b(anh|chi|co|chu|ban)\s+([a-z]+)[^,.!?]*?(\d+\s*(?:k|nghin|ngan|trieu|cu))\s*[,\.]?\s*(?:a\s+khong|khong\s+phai|sua\s+lai|nham|y\s+toi\s+la)[,\s]*\2\s+(\d+\s*(?:k|nghin|ngan|trieu|cu))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let honorificRange = Range(match.range(at: 1), in: normalized),
              let nameRange = Range(match.range(at: 2), in: normalized),
              let correctedAmountRange = Range(match.range(at: 4), in: normalized) else {
            return transcript
        }
        let replacement = "\(normalized[honorificRange]) \(normalized[nameRange]) \(normalized[correctedAmountRange])"
        return (normalized as NSString).replacingCharacters(in: match.range, with: replacement)
    }
}
