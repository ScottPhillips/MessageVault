import XCTest
@testable import MessageVault

final class MessageVaultTests: XCTestCase {
    func testAppleNanosecondDateConversion() {
        let date = MessageStore.appleDate(700_000_000_000_000_000)
        XCTAssertEqual(date.timeIntervalSinceReferenceDate, 700_000_000, accuracy: 0.001)
    }

    func testAppleSecondDateConversion() {
        let date = MessageStore.appleDate(700_000_000)
        XCTAssertEqual(date.timeIntervalSinceReferenceDate, 700_000_000, accuracy: 0.001)
    }

    func testHandleNormalization() {
        XCTAssertEqual(HandleNormalizer.normalize("+1 (415) 555-0100"), "+14155550100")
        XCTAssertEqual(HandleNormalizer.normalize(" Person@Example.COM "), "person@example.com")
        XCTAssertTrue(HandleNormalizer.phoneNumbersMatch("+14155550100", "(415) 555-0100"))
        XCTAssertFalse(HandleNormalizer.phoneNumbersMatch("+14155550100", "(212) 555-0100"))
    }

    func testContentClassification() {
        XCTAssertEqual(ContentCategory.classify(mime: "image/gif", uti: nil, filename: "x.gif"), .animatedImage)
        XCTAssertEqual(ContentCategory.classify(mime: "video/quicktime", uti: nil, filename: "x.mov"), .video)
        XCTAssertEqual(ContentCategory.classify(mime: "application/pdf", uti: nil, filename: "x.pdf"), .document)
        XCTAssertEqual(ContentCategory.classify(mime: nil, uti: nil, filename: "x.vcf"), .contactCard)
    }

    func testSemanticVersionComparison() {
        XCTAssertTrue(UpdateService.isNewer("v1.2.0", than: "1.1.9"))
        XCTAssertTrue(UpdateService.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateService.isNewer("v1.1.0", than: "1.1.0"))
        XCTAssertFalse(UpdateService.isNewer("1.0.9", than: "1.1.0"))
    }
}
