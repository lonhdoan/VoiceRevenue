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
            ("2 triệu", 2000000)
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


    func testSpeechRecognitionPlannerOnlineThenOnDeviceFallback() {
        XCTAssertEqual(
            SpeechRecognitionPlanner.orderedModes(
                networkAvailable: true,
                recognizerAvailable: true,
                supportsOnDevice: true
            ),
            [.online, .onDeviceFallback]
        )
        XCTAssertEqual(
            SpeechRecognitionPlanner.orderedModes(
                networkAvailable: false,
                recognizerAvailable: false,
                supportsOnDevice: true
            ),
            [.onDeviceFallback]
        )
    }

    func testAmbiguousTimeNeedsReview() {
        let values = TransactionParser.parse("lúc 7 giờ anh Nam 350 nghìn tiền biển neon")
        XCTAssertTrue(values.first?.needsReview ?? false)
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
    func testValidPing() async {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"ok":true,"pong":true,"service":"VoiceRevenue","version":"0.1.1","sheet_access":true}"#.data(using: .utf8)!
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
    func testSuccessfulAppendDuplicateOfflineAndRetry() async throws {
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
            let body = #"{"ok":true,"duplicate":false}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        XCTAssertTrue(await service.sync(item, context: context))
        XCTAssertEqual(item.syncStatus, SyncStatus.synced.rawValue)

        item.syncStatus = SyncStatus.pending.rawValue
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(await service.sync(item, context: context))
        XCTAssertEqual(item.syncStatus, SyncStatus.failed.rawValue)

        MockURLProtocol.requestHandler = { request in
            let body = #"{"ok":true,"duplicate":true}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        XCTAssertTrue(await service.sync(item, context: context))
        XCTAssertEqual(item.syncStatus, SyncStatus.synced.rawValue)
    }
}
