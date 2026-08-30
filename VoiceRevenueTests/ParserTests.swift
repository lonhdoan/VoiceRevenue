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

    func testCustomerCases() {
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

    func testMultipleTransactions() {
        let values = TransactionParser.parse("Anh Nam 300 nghìn biển A, chị Hoa 500 nghìn biển B, anh Minh 1 triệu biển C")
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0].amountVND, 300000)
        XCTAssertEqual(values[1].amountVND, 500000)
        XCTAssertEqual(values[2].amountVND, 1000000)
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

    func testAmbiguousTimeNeedsReview() {
        let values = TransactionParser.parse("lúc 7 giờ anh Nam 350 nghìn tiền biển neon")
        XCTAssertTrue(values.first?.needsReview ?? false)
    }
}
