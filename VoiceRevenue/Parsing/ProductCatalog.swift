import Foundation

struct CatalogProduct: Codable, Equatable, Hashable {
    let name: String
    let normalized: String
    let sourceSheet: String?
    let sourceRow: Int?
    let unit: String?
    let diameter: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case name
        case normalized
        case sourceSheet = "source_sheet"
        case sourceRow = "source_row"
        case unit
        case diameter
        case type
    }
}

struct ProductCatalogFile: Codable, Equatable {
    let catalogVersion: String
    let sourceFile: String
    let sourceSheets: [String]
    let rawProductRows: Int
    let productCount: Int
    let exactDuplicatesRemoved: Int
    let emptyNameRowsSkipped: Int
    let malformedRows: Int
    let normalizedCollisionsRetained: Int
    let products: [CatalogProduct]

    enum CodingKeys: String, CodingKey {
        case catalogVersion = "catalog_version"
        case sourceFile = "source_file"
        case sourceSheets = "source_sheets"
        case rawProductRows = "raw_product_rows"
        case productCount = "product_count"
        case exactDuplicatesRemoved = "exact_duplicates_removed"
        case emptyNameRowsSkipped = "empty_name_rows_skipped"
        case malformedRows = "malformed_rows"
        case normalizedCollisionsRetained = "normalized_collisions_retained"
        case products
    }
}

enum ProductCatalogLoader {
    static func loadBundled(bundle: Bundle = .main) -> ProductCatalogFile? {
        guard let url = bundle.url(forResource: "ProductCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProductCatalogFile.self, from: data)
    }
}

struct CatalogToken: Equatable {
    let raw: String
    let normalized: String
    let range: NSRange
}

enum ProductCatalogMatcher {
    private struct PreparedProduct {
        let name: String
        let normalized: String
        let tokenCount: Int
    }

    private struct RankedCandidate {
        let product: PreparedProduct
        let score: Double
        let secondBest: Double
    }

    private static let quantityUnits: Set<String> = [
        "m", "met", "cm", "mm", "cai", "bo", "hop", "cuon", "goi", "kg", "gam", "lit", "l"
    ]

    static func tokens(in raw: String) -> [CatalogToken] {
        guard let regex = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+(?:[\.,][\p{N}]+)*"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let nsRange = NSRange(raw.startIndex..., in: raw)
        return regex.matches(in: raw, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: raw) else { return nil }
            let text = String(raw[range])
            return CatalogToken(raw: text, normalized: VietnameseTextNormalizer.normalize(text), range: match.range)
        }
    }

    struct MatchResult: Equatable {
        let accepted: [ProductMatchEvidence]
        let rejected: [RejectedProductCandidate]
    }

    static func matchProducts(
        in rawProductText: String,
        vocabulary: [String],
        corrections: [String: String]
    ) -> [ProductMatchEvidence] {
        matchProductsWithTrace(
            in: rawProductText,
            vocabulary: vocabulary,
            corrections: corrections
        ).accepted
    }

    static func matchProductsWithTrace(
        in rawProductText: String,
        vocabulary: [String],
        corrections: [String: String]
    ) -> MatchResult {
        let tokens = tokens(in: rawProductText)
        guard !tokens.isEmpty else { return MatchResult(accepted: [], rejected: []) }

        let products = prepare(vocabulary)
        let exactIndex = Dictionary(grouping: products, by: { $0.normalized })
        let byTokenCount = Dictionary(grouping: products, by: { $0.tokenCount })
        let correctionEntries = corrections.compactMap { key, value -> (source: [String], sourceNormalized: String, canonical: String)? in
            let sourceNormalized = VietnameseTextNormalizer.normalize(key)
            let source = sourceNormalized.split(separator: " ").map(String.init)
            let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !canonical.isEmpty else { return nil }
            return (source, sourceNormalized, canonical)
        }.sorted { $0.source.count > $1.source.count }

        var occupied = Array(repeating: false, count: tokens.count)
        var evidence: [ProductMatchEvidence] = []
        var rejected: [RejectedProductCandidate] = []

        // Learned corrections are deterministic, but only when their exact normalized source
        // phrase actually occurs in the current product span.
        for correction in correctionEntries {
            let count = correction.source.count
            guard count <= tokens.count else { continue }
            for start in 0...(tokens.count - count) {
                guard rangeIsFree(start: start, count: count, occupied: occupied) else { continue }
                let phrase = normalizedPhrase(tokens: tokens, start: start, count: count)
                guard phrase == correction.sourceNormalized else { continue }
                let extended = quantityExtension(tokens: tokens, start: start, count: count, occupied: occupied)
                markOccupied(start: start, count: extended, occupied: &occupied)
                evidence.append(
                    ProductMatchEvidence(
                        sourcePhrase: rawPhrase(in: rawProductText, tokens: tokens, start: start, count: extended),
                        canonicalProduct: appendQuantityIfNeeded(
                            canonical: correction.canonical,
                            raw: rawProductText,
                            tokens: tokens,
                            start: start,
                            baseCount: count,
                            extendedCount: extended
                        ),
                        matchKind: .learnedCorrection,
                        score: 1.0,
                        tokenStart: start,
                        tokenCount: extended,
                        requiresReview: false
                    )
                )
            }
        }

        // Exact catalog/vocabulary matching. Longest phrase wins. If several canonical names
        // collapse to the same normalized spelling, do not silently choose one unless the raw
        // text itself uniquely identifies it.
        let maxTokenCount = min(products.map(\.tokenCount).max() ?? 1, 10)
        for start in tokens.indices where !occupied[start] {
            var chosen: ProductMatchEvidence?
            let available = min(maxTokenCount, tokens.count - start)
            if available > 0 {
                for count in stride(from: available, through: 1, by: -1) {
                    guard rangeIsFree(start: start, count: count, occupied: occupied) else { continue }
                    let phraseNormalized = normalizedPhrase(tokens: tokens, start: start, count: count)
                    guard let matches = exactIndex[phraseNormalized], !matches.isEmpty else { continue }

                    let raw = rawPhrase(in: rawProductText, tokens: tokens, start: start, count: count)
                    let rawFolded = raw.folding(options: [.caseInsensitive], locale: Locale(identifier: "vi_VN"))
                    let direct = matches.first { item in
                        item.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "vi_VN")) == rawFolded
                    }
                    guard let product = direct ?? (matches.count == 1 ? matches[0] : nil) else { continue }
                    let extended = quantityExtension(tokens: tokens, start: start, count: count, occupied: occupied)
                    chosen = ProductMatchEvidence(
                        sourcePhrase: rawPhrase(in: rawProductText, tokens: tokens, start: start, count: extended),
                        canonicalProduct: appendQuantityIfNeeded(
                            canonical: product.name,
                            raw: rawProductText,
                            tokens: tokens,
                            start: start,
                            baseCount: count,
                            extendedCount: extended
                        ),
                        matchKind: .vocabularyExact,
                        score: 1.0,
                        tokenStart: start,
                        tokenCount: extended,
                        requiresReview: false
                    )
                    break
                }
            }
            if let chosen {
                markOccupied(start: chosen.tokenStart, count: chosen.tokenCount, occupied: &occupied)
                evidence.append(chosen)
            }
        }

        // Fuzzy matching is LOCAL-WINDOW ONLY. There is deliberately no global "nearest
        // product" fallback. A weak/ambiguous candidate is rejected and the raw source phrase
        // is preserved for human review instead.
        var fuzzyCandidates: [ProductMatchEvidence] = []
        for start in tokens.indices where !occupied[start] {
            let maxWindow = min(8, tokens.count - start)
            for count in 1...maxWindow {
                guard rangeIsFree(start: start, count: count, occupied: occupied) else { break }
                let phrase = normalizedPhrase(tokens: tokens, start: start, count: count)
                guard shouldConsiderFuzzy(phrase: phrase, tokenCount: count),
                      let ranked = bestCandidate(for: phrase, tokenCount: count, groups: byTokenCount) else { continue }

                let sourcePhrase = rawPhrase(in: rawProductText, tokens: tokens, start: start, count: count)
                if fuzzyAccepted(
                    score: ranked.score,
                    secondBest: ranked.secondBest,
                    phrase: phrase,
                    tokenCount: count
                ) {
                    let extended = quantityExtension(tokens: tokens, start: start, count: count, occupied: occupied)
                    fuzzyCandidates.append(
                        ProductMatchEvidence(
                            sourcePhrase: rawPhrase(in: rawProductText, tokens: tokens, start: start, count: extended),
                            canonicalProduct: appendQuantityIfNeeded(
                                canonical: ranked.product.name,
                                raw: rawProductText,
                                tokens: tokens,
                                start: start,
                                baseCount: count,
                                extendedCount: extended
                            ),
                            matchKind: .fuzzySuggestion,
                            score: ranked.score,
                            tokenStart: start,
                            tokenCount: extended,
                            requiresReview: true
                        )
                    )
                } else if shouldLogRejectedFuzzy(score: ranked.score, tokenCount: count) {
                    rejected.append(
                        RejectedProductCandidate(
                            sourcePhrase: sourcePhrase,
                            canonicalProduct: ranked.product.name,
                            score: ranked.score,
                            secondBestScore: ranked.secondBest,
                            tokenStart: start,
                            tokenCount: count,
                            reason: fuzzyRejectionReason(
                                score: ranked.score,
                                secondBest: ranked.secondBest,
                                tokenCount: count
                            )
                        )
                    )
                }
            }
        }

        // Highest-confidence local fuzzy candidate wins first. Overlaps are diagnostic-only,
        // not emitted as products.
        for candidate in fuzzyCandidates.sorted(by: {
            if $0.score == $1.score { return $0.tokenCount > $1.tokenCount }
            return ($0.score ?? 0) > ($1.score ?? 0)
        }) {
            guard rangeIsFree(start: candidate.tokenStart, count: candidate.tokenCount, occupied: occupied) else {
                rejected.append(
                    RejectedProductCandidate(
                        sourcePhrase: candidate.sourcePhrase,
                        canonicalProduct: candidate.canonicalProduct,
                        score: candidate.score ?? 0,
                        secondBestScore: 0,
                        tokenStart: candidate.tokenStart,
                        tokenCount: candidate.tokenCount,
                        reason: "overlaps_stronger_evidence"
                    )
                )
                continue
            }
            markOccupied(start: candidate.tokenStart, count: candidate.tokenCount, occupied: &occupied)
            evidence.append(candidate)
        }

        // Preserve every remaining meaningful token span verbatim. Unknown text is safer than
        // inventing an accounting product.
        var index = 0
        while index < tokens.count {
            if occupied[index] {
                index += 1
                continue
            }
            let start = index
            while index < tokens.count && !occupied[index] { index += 1 }
            let count = index - start
            guard count > 0 else { continue }
            let raw = rawPhrase(in: rawProductText, tokens: tokens, start: start, count: count)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !raw.isEmpty, !isIgnorableResidual(raw) else { continue }
            evidence.append(
                ProductMatchEvidence(
                    sourcePhrase: raw,
                    canonicalProduct: raw,
                    matchKind: .raw,
                    score: nil,
                    tokenStart: start,
                    tokenCount: count,
                    requiresReview: true
                )
            )
        }

        let accepted = deduplicatedEvidence(evidence).sorted { lhs, rhs in
            if lhs.tokenStart == rhs.tokenStart { return lhs.tokenCount > rhs.tokenCount }
            return lhs.tokenStart < rhs.tokenStart
        }
        let rejectedSorted = rejected
            .filter { candidate in
                !accepted.contains { acceptedItem in
                    acceptedItem.tokenStart == candidate.tokenStart &&
                    acceptedItem.tokenCount == candidate.tokenCount &&
                    VietnameseTextNormalizer.normalize(acceptedItem.canonicalProduct) ==
                    VietnameseTextNormalizer.normalize(candidate.canonicalProduct)
                }
            }
            .sorted { lhs, rhs in
                if lhs.tokenStart == rhs.tokenStart { return lhs.score > rhs.score }
                return lhs.tokenStart < rhs.tokenStart
            }

        return MatchResult(accepted: accepted, rejected: rejectedSorted)
    }

    static func contextualShortlist(
        from transcript: String,
        vocabulary: [String],
        priority: [String],
        limit: Int = 100
    ) -> [String] {
        let cappedLimit = max(0, min(limit, 100))
        guard cappedLimit > 0 else { return [] }

        let products = prepare(vocabulary)
        let byTokenCount = Dictionary(grouping: products, by: { $0.tokenCount })
        let exactIndex = Dictionary(grouping: products, by: { $0.normalized })
        let tokens = tokens(in: transcript)
        var scored: [(String, Double)] = []

        for start in tokens.indices {
            let maxWindow = min(8, tokens.count - start)
            for count in 1...maxWindow {
                let phrase = normalizedPhrase(tokens: tokens, start: start, count: count)
                if let exact = exactIndex[phrase], exact.count == 1 {
                    scored.append((exact[0].name, 1.0))
                    continue
                }
                guard shouldConsiderFuzzy(phrase: phrase, tokenCount: count),
                      let ranked = bestCandidate(for: phrase, tokenCount: count, groups: byTokenCount),
                      shortlistAccepted(score: ranked.score, secondBest: ranked.secondBest, phrase: phrase, tokenCount: count) else { continue }
                scored.append((ranked.product.name, ranked.score))
            }
        }

        var seen = Set<String>()
        var output: [String] = []
        for item in scored.sorted(by: { $0.1 > $1.1 }).map(\.0) + priority {
            let key = VietnameseTextNormalizer.normalize(item)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(item)
            if output.count == cappedLimit { break }
        }
        return output
    }

    static func exactEvidenceCount(in transcript: String, vocabulary: [String]) -> Int {
        let products = prepare(vocabulary)
        let exact = Set(products.map(\.normalized))
        let tokens = tokens(in: transcript)
        guard !tokens.isEmpty else { return 0 }
        let maxTokenCount = min(products.map(\.tokenCount).max() ?? 1, 10)
        var hits = 0
        var occupied = Array(repeating: false, count: tokens.count)
        for start in tokens.indices where !occupied[start] {
            let available = min(maxTokenCount, tokens.count - start)
            for count in stride(from: available, through: 1, by: -1) {
                guard rangeIsFree(start: start, count: count, occupied: occupied) else { continue }
                let phrase = normalizedPhrase(tokens: tokens, start: start, count: count)
                if exact.contains(phrase) {
                    markOccupied(start: start, count: count, occupied: &occupied)
                    hits += 1
                    break
                }
            }
        }
        return hits
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
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

    private static func prepare(_ vocabulary: [String]) -> [PreparedProduct] {
        var seen = Set<String>()
        return vocabulary.compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = VietnameseTextNormalizer.normalize(name)
            guard !normalized.isEmpty else { return nil }
            let exactKey = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "vi_VN"))
            guard seen.insert(exactKey).inserted else { return nil }
            let tokenCount = normalized.split(separator: " ").count
            guard tokenCount > 0 else { return nil }
            return PreparedProduct(name: name, normalized: normalized, tokenCount: tokenCount)
        }
    }

    private static func bestCandidate(
        for phrase: String,
        tokenCount: Int,
        groups: [Int: [PreparedProduct]]
    ) -> RankedCandidate? {
        guard let candidates = groups[tokenCount], !candidates.isEmpty else { return nil }
        var bestProduct: PreparedProduct?
        var bestScore = 0.0
        var secondBest = 0.0
        for product in candidates {
            let score = similarity(phrase, product.normalized)
            if score > bestScore {
                secondBest = bestScore
                bestScore = score
                bestProduct = product
            } else if score > secondBest {
                secondBest = score
            }
        }
        guard let bestProduct else { return nil }
        return RankedCandidate(product: bestProduct, score: bestScore, secondBest: secondBest)
    }

    private static func shouldConsiderFuzzy(phrase: String, tokenCount: Int) -> Bool {
        let compactLength = phrase.replacingOccurrences(of: " ", with: "").count
        if tokenCount == 1 { return compactLength >= 5 }
        return compactLength >= 6
    }

    private static func fuzzyAccepted(score: Double, secondBest: Double, phrase: String, tokenCount: Int) -> Bool {
        let margin = score - secondBest
        switch tokenCount {
        case 1:
            return score >= 0.86 && margin >= 0.14
        case 2:
            // Allows "tap gym" -> "dập ghim" as review-required while rejecting weak global guesses.
            return score >= 0.62 && margin >= 0.05
        case 3:
            return score >= 0.70 && margin >= 0.07
        case 4:
            return score >= 0.74 && margin >= 0.08
        default:
            return score >= 0.78 && margin >= 0.08
        }
    }

    private static func shortlistAccepted(score: Double, secondBest: Double, phrase: String, tokenCount: Int) -> Bool {
        let margin = score - secondBest
        switch tokenCount {
        case 1: return score >= 0.84 && margin >= 0.12
        case 2: return score >= 0.60 && margin >= 0.045
        case 3: return score >= 0.68 && margin >= 0.06
        case 4: return score >= 0.72 && margin >= 0.07
        default: return score >= 0.76 && margin >= 0.07
        }
    }

    private static func shouldLogRejectedFuzzy(score: Double, tokenCount: Int) -> Bool {
        if tokenCount == 1 { return score >= 0.70 }
        return score >= 0.50
    }

    private static func fuzzyRejectionReason(score: Double, secondBest: Double, tokenCount: Int) -> String {
        let margin = score - secondBest
        let thresholds: (score: Double, margin: Double)
        switch tokenCount {
        case 1: thresholds = (0.86, 0.14)
        case 2: thresholds = (0.62, 0.05)
        case 3: thresholds = (0.70, 0.07)
        case 4: thresholds = (0.74, 0.08)
        default: thresholds = (0.78, 0.08)
        }
        if score < thresholds.score { return "below_score_threshold" }
        if margin < thresholds.margin { return "ambiguous_nearest_products" }
        return "not_accepted"
    }

    private static func normalizedPhrase(tokens: [CatalogToken], start: Int, count: Int) -> String {
        tokens[start..<(start + count)].map(\.normalized).joined(separator: " ")
    }

    private static func rawPhrase(in raw: String, tokens: [CatalogToken], start: Int, count: Int) -> String {
        let first = tokens[start].range
        let last = tokens[start + count - 1].range
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard let swiftRange = Range(range, in: raw) else { return "" }
        return String(raw[swiftRange])
    }

    private static func rangeIsFree(start: Int, count: Int, occupied: [Bool]) -> Bool {
        guard start >= 0, count > 0, start + count <= occupied.count else { return false }
        return !occupied[start..<(start + count)].contains(true)
    }

    private static func markOccupied(start: Int, count: Int, occupied: inout [Bool]) {
        guard start >= 0, count > 0, start + count <= occupied.count else { return }
        for index in start..<(start + count) { occupied[index] = true }
    }

    private static func quantityExtension(tokens: [CatalogToken], start: Int, count: Int, occupied: [Bool]) -> Int {
        let next = start + count
        guard next < tokens.count, !occupied[next] else { return count }
        let number = tokens[next].normalized
        guard Double(number.replacingOccurrences(of: ",", with: ".")) != nil else { return count }
        let unitIndex = next + 1
        guard unitIndex < tokens.count, !occupied[unitIndex], quantityUnits.contains(tokens[unitIndex].normalized) else {
            return count + 1
        }
        return count + 2
    }

    private static func appendQuantityIfNeeded(
        canonical: String,
        raw: String,
        tokens: [CatalogToken],
        start: Int,
        baseCount: Int,
        extendedCount: Int
    ) -> String {
        guard extendedCount > baseCount else { return canonical }
        let quantity = rawPhrase(
            in: raw,
            tokens: tokens,
            start: start + baseCount,
            count: extendedCount - baseCount
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quantity.isEmpty else { return canonical }
        let normalizedCanonical = VietnameseTextNormalizer.normalize(canonical)
        let normalizedQuantity = VietnameseTextNormalizer.normalize(quantity)
        if normalizedCanonical.hasSuffix(normalizedQuantity) { return canonical }
        return "\(canonical) \(quantity)"
    }

    private static func deduplicatedEvidence(_ values: [ProductMatchEvidence]) -> [ProductMatchEvidence] {
        var seen = Set<String>()
        return values.filter { value in
            let key = "\(value.tokenStart):\(value.tokenCount):\(VietnameseTextNormalizer.normalize(value.canonicalProduct))"
            return seen.insert(key).inserted
        }
    }

    private static func isIgnorableResidual(_ raw: String) -> Bool {
        let normalized = VietnameseTextNormalizer.normalize(raw)
        let stopwords: Set<String> = [
            "anh", "chi", "co", "chu", "ban", "tra", "thanh toan", "tien", "cho", "cai",
            "gom", "bao gom", "mua", "lay", "luc", "khoang", "gio", "nghin", "ngan", "trieu",
            "cu", "vnd", "dong", "la", "va"
        ]
        return normalized.isEmpty || stopwords.contains(normalized) || Int(normalized) != nil
    }
}
