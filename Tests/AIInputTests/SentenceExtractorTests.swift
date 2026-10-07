import XCTest
@testable import AIInput

final class SentenceExtractorTests: XCTestCase {
    private let text = "It was a long day. He was simply curious about the noise, and that led him down a path. Nobody noticed."

    func testReturnsTheSentenceAroundTheSelectionUsingTheRange() {
        let range = (text as NSString).range(of: "curious")
        XCTAssertEqual(
            SentenceExtractor.sentence(in: text, selectedRange: range, selected: "curious"),
            "He was simply curious about the noise, and that led him down a path."
        )
    }

    func testFallsBackToSearchingWhenTheRangeDoesNotMatch() {
        XCTAssertEqual(
            SentenceExtractor.sentence(in: text, selectedRange: NSRange(location: 3, length: 7), selected: "Nobody"),
            "Nobody noticed."
        )
    }

    func testNoContextWhenSelectionIsTheWholeSentenceOrSpansSentences() {
        XCTAssertNil(SentenceExtractor.sentence(in: "Nobody noticed.", selectedRange: nil, selected: "Nobody noticed."))
        XCTAssertNil(SentenceExtractor.sentence(in: text, selectedRange: nil, selected: "day. He was"))
    }

    func testNoContextForMissingSelectionOrHugeText() {
        XCTAssertNil(SentenceExtractor.sentence(in: text, selectedRange: nil, selected: "absent"))
        let huge = String(repeating: "word ", count: 20_000) + "curious."
        XCTAssertNil(SentenceExtractor.sentence(in: huge, selectedRange: nil, selected: "curious"))
    }

    func testNewlinesInsideASentenceAreCollapsed() {
        let wrapped = "He was simply\ncurious about\nthe noise."
        XCTAssertEqual(
            SentenceExtractor.sentence(in: wrapped, selectedRange: nil, selected: "curious"),
            "He was simply curious about the noise."
        )
    }
}
