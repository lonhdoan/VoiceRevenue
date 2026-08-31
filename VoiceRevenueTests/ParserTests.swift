import CoreData
import XCTest
@testable import VoiceRevenue

final class ParserTests: XCTestCase {
    func testMoneyCases() {
        let cases: [(String, Int64)] = [
            ("350 nghìn", 350000),
            ("350 ngàn", 350000),
            ("350k", 350000),
            ("350 K", 350000),
            ("350.000", 350000),
            ("350000", 350000),
            ("1 triệu", 1000000),
            ("1 triệu 2", 1200000),
            ("1 triệu 200", 1200000),
            ("1 triệu rưỡi", 1500000),
            ("một triệu hai", 1200000),
            ("một triệu rưỡi", 1500000),
            ("một củ", 1000000),
            ("một củ hai", 1200000),
            ("hai củ rưỡi", 2500000),
            ("ba trăm rưỡi", 350000),
            ("ba trăm năm mươi nghìn", 350000),
            ("2 triệu", 2000000),
            ("1tr2", 1200000)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(VietnameseMoneyParser.firstAmount(in: input)?.value, expected, input)
        }
    }

    func testTimeCases() {
        let cases: [(String, Int, Int, Bool)] = [
            ("7 giờ tối", 19, 0, false),
            ("7 rưỡi tối", 19, 30, false),
            ("19 giờ 30", 19, 30, false),
            ("19:30", 19, 30, false),
            ("7 giờ sáng", 7, 0, false),
            ("7 giờ", 7, 0, true),
            ("7 rưỡi", 7, 30, true),
            ("lúc 7", 7, 0, true),
            ("khoảng 7 giờ", 7, 0, true)
        ]
        for (input, h, m, ambiguous) in cases {
            let value = VietnameseTimeParser.firstTime(in: input)
            XCTAssertEqual(value?.hour, h, input)
            XCTAssertEqual(value?.minute, m, input)
            XCTAssertEqual(value?.isAmbiguous, ambiguous, input)
        }
    }

    func testCustomerCasesPreserveVietnamese() {
        let cases: [(String, String)] = [
            ("anh Nam trả tiền", "Nam"),
            ("chị Hương thanh toán", "Hương"),
            ("cô Lan 300 nghìn", "Lan"),
            ("chú Minh tiền mặt", "Minh"),
            ("bạn An chuyển khoản", "An")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TransactionParser.extractCustomer(from: input), expected)
        }
    }

    func testPaymentMethods() {
        XCTAssertEqual(TransactionParser.extractPaymentMethod(from: VietnameseTextNormalizer.normalize("chuyển khoản")), .bankTransfer)
        XCTAssertEqual(TransactionParser.extractPaymentMethod(from: VietnameseTextNormalizer.normalize("bank transfer")), .bankTransfer)
        XCTAssertEqual(TransactionParser.extractPaymentMethod(from: VietnameseTextNormalizer.normalize("tiền mặt")), .cash)
        XCTAssertEqual(TransactionParser.extractPaymentMethod(from: VietnameseTextNormalizer.normalize("cash")), .cash)
        XCTAssertEqual(TransactionParser.extractPaymentMethod(from: "không nói"), .unknown)
    }

    func testDiacriticsArePreservedInProductOutput() {
        let values = TransactionParser.parse("Anh Nam 50 nghìn dây điện")
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.product, "dây điện")
        XCTAssertNotEqual(values.first?.product, "day dien")
    }

    func testVocabularyFuzzySuggestionForSpeechError() {
        let values = TransactionParser.parse(
            "tập gym năm mươi nghìn",
            vocabulary: ["dập ghim"]
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.product, "dập ghim")
        XCTAssertEqual(values.first?.productMatchKind, .fuzzySuggestion)
        XCTAssertTrue(values.first?.needsReview ?? false)
    }

    func testLearnedCorrectionAutoApplies() {
        let values = TransactionParser.parse(
            "tập gym năm mươi nghìn",
            vocabulary: ["dập ghim"],
            corrections: ["tap gym": "dập ghim"]
        )
        XCTAssertEqual(values.first?.product, "dập ghim")
        XCTAssertEqual(values.first?.productMatchKind, .learnedCorrection)
    }

    func testMultipleItemsStayOneTransactionAndAreReadable() {
        let values = TransactionParser.parse(
            "Anh Nam trả 250 nghìn gồm dây điện 5 mét, bấm móng tay và dập ghim.",
            vocabulary: ["dập ghim", "dây điện", "bấm móng tay", "ốc vít"]
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.amountVND, 250000)
        XCTAssertEqual(values.first?.product, "dây điện 5 mét\nbấm móng tay\ndập ghim")
    }

    func testMultipleTransactions() {
        let values = TransactionParser.parse(
            "Anh Nam 50 nghìn ốc vít, chị Hương 120 nghìn dây điện",
            vocabulary: ["ốc vít", "dây điện"]
        )
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].amountVND, 50000)
        XCTAssertEqual(values[0].product, "ốc vít")
        XCTAssertEqual(values[1].amountVND, 120000)
        XCTAssertEqual(values[1].product, "dây điện")
    }

    func testRepeatedAmountsWithoutCustomerCanSplitAtPunctuation() {
        let values = TransactionParser.parse(
            "50 nghìn ốc vít, 80 nghìn dập ghim",
            vocabulary: ["ốc vít", "dập ghim"]
        )
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.allSatisfy { $0.needsReview })
    }

    func testExplicitCorrection() {
        let values = TransactionParser.parse("Anh Nam 350 nghìn, à không Nam 380 nghìn")
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.amountVND, 380000)
    }

    func testMissingAmountNeedsReview() {
        let values = TransactionParser.parse("Anh Nam tiền cái biển neon")
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values.first?.amountVND)
        XCTAssertTrue(values.first?.needsReview ?? false)
    }

    func testEmptyTranscriptNeverCreatesCandidate() {
        XCTAssertTrue(TransactionParser.parse("").isEmpty)
        XCTAssertTrue(TransactionParser.parse("   \n  ").isEmpty)
    }


    func testMoneyCueGrammarDoesNotLeakIntoProduct() {
        let vocabulary = ["bút bi", "dây điện", "giá đỡ điện thoại", "ốc vít"]

        let a = TransactionParser.parse("bút bi giá 20 nghìn", vocabulary: vocabulary)
        XCTAssertEqual(a.first?.product?.lowercased(), "bút bi")
        XCTAssertEqual(a.first?.amountVND, 20_000)

        let b = TransactionParser.parse("giá 50 nghìn dây điện", vocabulary: vocabulary)
        XCTAssertEqual(b.first?.product?.lowercased(), "dây điện")
        XCTAssertEqual(b.first?.amountVND, 50_000)

        let c = TransactionParser.parse("giá 50 nghìn", vocabulary: vocabulary)
        XCTAssertNil(c.first?.product)
        XCTAssertEqual(c.first?.amountVND, 50_000)
        XCTAssertTrue(c.first?.needsReview ?? false)

        let d = TransactionParser.parse("giá đỡ điện thoại 50 nghìn", vocabulary: vocabulary)
        XCTAssertEqual(d.first?.product?.lowercased(), "giá đỡ điện thoại")
        XCTAssertEqual(d.first?.amountVND, 50_000)

        let e = TransactionParser.parse("ốc vít tiền 30 nghìn", vocabulary: vocabulary)
        XCTAssertEqual(e.first?.product?.lowercased(), "ốc vít")
        XCTAssertEqual(e.first?.amountVND, 30_000)
    }

    func testRealDevicePriceCueRegression() {
        let values = TransactionParser.parse("Vít 20 giá 10.000", vocabulary: ["Vít 20"])
        XCTAssertEqual(values.first?.amountVND, 10_000)
        XCTAssertEqual(values.first?.product, "Vít 20")
    }

    func testOpenSpeechArbitrationIsDeterministic() {
        let local = "bút bi giá 20 nghìn"
        let remote = "bút bi hai mươi nghìn"
        let result = SpeechTranscriptArbitrator.choose(
            local: local,
            remote: remote,
            catalogProducts: ["Bút bi", "Dây điện"]
        )
        XCTAssertFalse(result.selected.isEmpty)
        XCTAssertTrue([local, remote].contains(result.selected))
        XCTAssertNotEqual(result.selected, "dây điện")
    }

    @MainActor
    func testDiagnosticExportKeepsPriorSession() throws {
        let first = DiagnosticLogger()
        first.clearLogs()
        first.log(event: "test.previous.session", payload: ["value": "one"])

        let second = DiagnosticLogger()
        second.log(event: "test.current.session", payload: ["value": "two"])
        guard let export = second.exportURL() else {
            XCTFail("Missing diagnostic export")
            return
        }
        let text = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(text.contains("test.previous.session"))
        XCTAssertTrue(text.contains("test.current.session"))
    }


    func testCatalogResourceLoadsAtScale() {
        let catalog = ProductCatalogLoader.loadBundled()
        XCTAssertNotNil(catalog)
        XCTAssertGreaterThanOrEqual(catalog?.productCount ?? 0, 1000)
        XCTAssertEqual(catalog?.malformedRows, 0)
        XCTAssertTrue(catalog?.products.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
        XCTAssertTrue(catalog?.products.contains(where: { $0.name == "Dập ghim" }) ?? false)
        XCTAssertTrue(catalog?.products.contains(where: { $0.name == "Bút bi" }) ?? false)
    }

    func testFalsePositiveRegressionDoesNotInventDayDien() {
        let realCatalog = ProductCatalogLoader.loadBundled()?.products.map(\.name) ?? []
        let catalog = realCatalog + ["dập ghim", "dây điện"]
        let values = TransactionParser.parse(
            "Tập Gym thước kẻ bút bi 50.000",
            vocabulary: catalog
        )
        XCTAssertEqual(values.count, 1)
        let lines = Set(
            (values.first?.product ?? "")
                .components(separatedBy: .newlines)
                .map(VietnameseTextNormalizer.normalize)
        )
        XCTAssertFalse(lines.contains("day dien"))
        XCTAssertTrue(lines.contains("but bi"))
        XCTAssertTrue(lines.contains("thuoc ke"))
        XCTAssertTrue(lines.contains("dap ghim"))
        XCTAssertTrue(values.first?.needsReview ?? false)
    }

    func testLearnedCorrectionRequiresSourceEvidence() {
        let corrections = ["tap gym": "dập ghim"]
        let corrected = TransactionParser.parse(
            "tập gym 50 nghìn",
            vocabulary: ["dập ghim", "thước kẻ"],
            corrections: corrections
        )
        XCTAssertEqual(corrected.first?.product, "dập ghim")
        XCTAssertEqual(corrected.first?.productMatchKind, .learnedCorrection)

        let unrelated = TransactionParser.parse(
            "thước kẻ 50 nghìn",
            vocabulary: ["dập ghim", "thước kẻ"],
            corrections: corrections
        )
        XCTAssertEqual(unrelated.first?.product, "thước kẻ")
        XCTAssertFalse((unrelated.first?.product ?? "").contains("dập ghim"))
    }

    func testMultiItemEvidenceBackedProducts() {
        let values = TransactionParser.parse(
            "dập ghim thước kẻ bút bi 50 nghìn",
            vocabulary: ["dập ghim", "bút bi"]
        )
        XCTAssertEqual(values.count, 1)
        let lines = (values.first?.product ?? "").components(separatedBy: .newlines)
        XCTAssertEqual(lines, ["dập ghim", "thước kẻ", "bút bi"])
    }

    func testUnknownProductStaysRawAndNeedsReview() {
        let values = TransactionParser.parse(
            "abcxyz 50 nghìn",
            vocabulary: ["dập ghim", "dây điện", "bút bi"]
        )
        XCTAssertEqual(values.first?.product, "abcxyz")
        XCTAssertTrue(values.first?.needsReview ?? false)
        XCTAssertNotEqual(values.first?.product, "dập ghim")
        XCTAssertNotEqual(values.first?.product, "dây điện")
    }

    func testContextualShortlistIsEvidenceBounded() {
        let shortlist = ProductCatalogMatcher.contextualShortlist(
            from: "tập gym thước kẻ bút bi năm mươi nghìn",
            vocabulary: ["dập ghim", "dây điện", "bút bi", "ốc vít"],
            priority: []
        )
        XCTAssertTrue(shortlist.contains("dập ghim"))
        XCTAssertTrue(shortlist.contains("bút bi"))
        XCTAssertFalse(shortlist.contains("dây điện"))
    }

    func testMatcherKeepsRejectedCandidatesDiagnosticOnly() {
        let result = ProductCatalogMatcher.matchProductsWithTrace(
            in: "thước kẻ bút bi",
            vocabulary: ["dập ghim", "dây điện", "bút bi", "ốc vít"],
            corrections: [:]
        )
        XCTAssertFalse(result.accepted.contains {
            VietnameseTextNormalizer.normalize($0.canonicalProduct) == "day dien"
        })
        XCTAssertTrue(result.accepted.contains {
            VietnameseTextNormalizer.normalize($0.canonicalProduct) == "but bi"
        })
    }

    func testAmbiguousTimeNeedsReview() {
        let values = TransactionParser.parse("lúc 7 giờ anh Nam 350 nghìn tiền biển neon")
        XCTAssertTrue(values.first?.needsReview ?? false)
    }

    @MainActor
    func testHistoryEditPreservesIdentityAndMarksPending() throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = TransactionRepository(context: persistence.container.viewContext)
        try repository.save(
            CandidateTransaction(amountVND: 50_000, customerName: "Nam", product: "ốc vít"),
            transcript: "Nam 50 nghìn ốc vít"
        )
        guard let item = repository.transactions.first else {
            XCTFail("Missing transaction")
            return
        }
        let originalID = item.transactionID
        let originalCreatedAt = item.createdAt

        try repository.update(
            item,
            amountVND: 70_000,
            customerName: "Hương",
            product: "dây điện",
            paymentMethod: .bankTransfer,
            paymentAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "đã sửa",
            markForSync: true
        )

        guard let edited = repository.transactions.first else {
            XCTFail("Missing edited transaction")
            return
        }
        XCTAssertEqual(edited.transactionID, originalID)
        XCTAssertEqual(edited.createdAt, originalCreatedAt)
        XCTAssertEqual(edited.amountVND, 70_000)
        XCTAssertEqual(edited.customerName, "Hương")
        XCTAssertEqual(edited.product, "dây điện")
        XCTAssertEqual(edited.paymentMethod, PaymentMethod.bankTransfer.rawValue)
        XCTAssertEqual(edited.syncStatus, SyncStatus.pending.rawValue)
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class GoogleSheetsSyncTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    func testRejectsMalformedAndDevURLs() async {
        let service = GoogleSheetsSyncService(session: makeSession())
        service.webAppURLString = "http://example.com/test"
        XCTAssertFalse(await service.testConnection())
        XCTAssertNotNil(service.lastError)

        service.webAppURLString = "https://script.google.com/macros/s/abc/dev"
        XCTAssertFalse(await service.testConnection())
        XCTAssertTrue(service.lastError?.contains("/dev") ?? false)
    }

    @MainActor
    func testEmptyURLRemainsNotConfigured() async {
        let service = GoogleSheetsSyncService(session: makeSession())
        service.webAppURLString = ""
        XCTAssertFalse(await service.testConnection())
        XCTAssertEqual(service.connectionStatus, .notConfigured)
    }

    @MainActor
    func testValidPing() async {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"ok":true,"pong":true,"service":"VoiceRevenue","version":"0.2.0","sheet_access":true}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
        }
        let service = GoogleSheetsSyncService(session: makeSession())
        service.webAppURLString = "https://script.google.com/macros/s/abc/exec"
        XCTAssertTrue(await service.testConnection())
        XCTAssertEqual(service.connectionStatus, .connected)
    }

    @MainActor
    func testHTTP403AndNonJSONAndRemoteError() async {
        let service = GoogleSheetsSyncService(session: makeSession())
        service.webAppURLString = "https://script.google.com/macros/s/abc/exec"

        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data("Forbidden".utf8))
        }
        XCTAssertFalse(await service.testConnection())
        XCTAssertTrue(service.lastError?.contains("403") ?? false)

        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, Data("<html>Sign in</html>".utf8))
        }
        XCTAssertFalse(await service.testConnection())
        XCTAssertTrue(service.lastError?.contains("đăng nhập") ?? false)

        MockURLProtocol.requestHandler = { request in
            let body = #"{"ok":false,"error":"sheet denied"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        XCTAssertFalse(await service.testConnection())
    }

    @MainActor
    func testSuccessfulCreateOfflineAndUpdateRetry() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let repository = TransactionRepository(context: context)
        try repository.save(
            CandidateTransaction(amountVND: 50000, customerName: "Nam", product: "ốc vít"),
            transcript: "Anh Nam 50 nghìn ốc vít"
        )
        guard let item = repository.transactions.first else {
            XCTFail("Missing transaction")
            return
        }

        let service = GoogleSheetsSyncService(session: makeSession())
        service.webAppURLString = "https://script.google.com/macros/s/abc/exec"

        MockURLProtocol.requestHandler = { request in
            let body = #"{"ok":true,"action":"created"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        XCTAssertTrue(await service.sync(item, context: context))
        XCTAssertEqual(item.syncStatus, SyncStatus.synced.rawValue)

        item.syncStatus = SyncStatus.pending.rawValue
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(await service.sync(item, context: context))
        XCTAssertEqual(item.syncStatus, SyncStatus.failed.rawValue)

        MockURLProtocol.requestHandler = { request in
            let body = #"{"ok":true,"action":"updated"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        XCTAssertTrue(await service.sync(item, context: context))
        XCTAssertEqual(item.syncStatus, SyncStatus.synced.rawValue)
    }
}
