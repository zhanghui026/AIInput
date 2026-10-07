import XCTest
@testable import AIInput

final class SelectionClassifierTests: XCTestCase {
    func testSingleWordsAreWords() {
        XCTAssertEqual(SelectionClassifier.kind(for: "curious"), .word)
        XCTAssertEqual(SelectionClassifier.kind(for: "  well-known "), .word)
        XCTAssertEqual(SelectionClassifier.kind(for: "don't"), .word)
    }

    func testShortFragmentsAreAPhraseAndFullSentencesAreSentences() {
        XCTAssertEqual(SelectionClassifier.kind(for: "rush to conclusions"), .phrase)
        XCTAssertEqual(SelectionClassifier.kind(for: "I agree."), .sentence)
        XCTAssertEqual(SelectionClassifier.kind(for: "Why did he leave so early?"), .sentence)
        XCTAssertEqual(SelectionClassifier.kind(for: "it was not that he knew more than the others there"), .sentence,
                       "超过 8 个词没有标点也按句子")
    }

    func testNonEnglishAndOversizedSelectionsHaveNoCard() {
        XCTAssertNil(SelectionClassifier.kind(for: "你好"))
        XCTAssertNil(SelectionClassifier.kind(for: "好奇"))
        XCTAssertNil(SelectionClassifier.kind(for: "12345"))
        XCTAssertNil(SelectionClassifier.kind(for: "https://example.com/page"))
        XCTAssertNil(SelectionClassifier.kind(for: String(repeating: "word ", count: 90)))
        XCTAssertNil(SelectionClassifier.kind(for: "   "))
    }

    func testNormalizedIgnoresCaseWhitespaceAndEdgePunctuation() {
        XCTAssertEqual(SelectionClassifier.normalized("  “Rush   to Conclusions!” "), "rush to conclusions")
    }

    func testLookupKeyMergesInflectionsOfAWord() {
        XCTAssertEqual(LookupKey.make(kind: .word, text: "Rushed"), LookupKey.make(kind: .word, text: "rush"))
        XCTAssertNotEqual(LookupKey.make(kind: .word, text: "rush"), LookupKey.make(kind: .phrase, text: "rush"))
        XCTAssertEqual(LookupKey.make(kind: .phrase, text: "Rush to conclusions."),
                       LookupKey.make(kind: .phrase, text: "rush to  conclusions"))
    }
}
