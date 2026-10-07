import XCTest
@testable import AIInput

final class CardStreamParserTests: XCTestCase {
    private let head = #"{"type":"head","lemma":"curious","ipa":"/ˈkjʊəriəs/","pos":"adj.","level":"B1"}"#
    private let senses = #"{"type":"senses","items":[{"zh":"好奇的","pos":"adj.","en":"She was curious.","enzh":"她很好奇。"}]}"#
    private let family = #"{"type":"family","items":["observer","led down"]}"#

    func testParsesOneObjectPerLine() {
        let parser = CardStreamParser()
        let blocks = parser.update(with: [head, senses, family].joined(separator: "\n"))
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.head?.level, "B1")
        XCTAssertEqual(blocks.firstGloss, "好奇的")
    }

    func testToleratesPreambleFencesAndMultiLineObjects() {
        let text = """
        Here is the card:
        ```json
        {"type":"teacher",
          "en":"When someone is curious, they want to learn more.",
          "zh":"好奇"}
        ```
        \(family) \(head)
        """
        let blocks = CardStreamParser().update(with: text)
        XCTAssertEqual(blocks.count, 3, "多行对象、同一行两个对象都要认出来")
        guard case .teacher(let teacher) = blocks[0] else { return XCTFail("first block should be teacher") }
        XCTAssertEqual(teacher.zh, "好奇")
    }

    func testBracesAndQuotesInsideStringsDoNotBreakScanning() {
        let line = #"{"type":"note","title":"语法点","text":"a } brace, a \" quote and a { brace"}"#
        let blocks = CardStreamParser().update(with: line)
        XCTAssertEqual(blocks, [.note(CardNote(title: "语法点", text: #"a } brace, a " quote and a { brace"#))])
    }

    func testIncrementalFeedingEmitsEachBlockOnceAndHoldsTheTruncatedTail() {
        let parser = CardStreamParser()
        let full = head + "\n" + senses + "\n" + family
        var received: [CardBlock] = []
        var text = ""
        for character in full {
            text.append(character)
            received += parser.update(with: text)
        }
        XCTAssertEqual(received.count, 3)

        let truncated = CardStreamParser()
        XCTAssertEqual(truncated.update(with: head + "\n" + #"{"type":"senses","items":[{"zh":"好"#).count, 1)
    }

    func testSkipsInlineThinkingBlock() {
        let parser = CardStreamParser()
        XCTAssertTrue(parser.update(with: "<think>I should output {\"type\":").isEmpty)
        let blocks = parser.update(with: "<think>I should output {\"type\":\"x\"}</think>\n" + head)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.head?.lemma, "curious")
    }

    func testDropsInvalidAndEmptyBlocksButKeepsTheRest() {
        let text = [
            #"{"type":"senses","items":[{"pos":"adj."}]}"#,   // 缺 zh
            #"{"type":"family","items":[]}"#,                 // 空
            #"{"type":"mystery","x":1}"#,                     // 未知类型
            family,
        ].joined(separator: "\n")
        XCTAssertEqual(CardStreamParser().update(with: text), [.family(CardChips(items: ["observer", "led down"]))])
    }

    func testBlocksRoundTripThroughCodable() throws {
        let blocks: [CardBlock] = [
            .head(CardHead(lemma: "rush", ipa: nil, pos: nil, level: nil, label: "短语 / Phrase")),
            .translation(CardTranslation(literal: "冲向结论", natural: "草率下结论")),
            .pattern(CardPattern(skeleton: "rush to + N", variants: ["rush to judgment"], drill: "rush to a ____")),
            .unknown("future"),
        ]
        let data = try JSONEncoder().encode(blocks)
        XCTAssertEqual(try JSONDecoder().decode([CardBlock].self, from: data), blocks)
    }
}
