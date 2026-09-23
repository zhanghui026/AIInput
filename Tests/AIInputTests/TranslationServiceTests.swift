import XCTest
@testable import AIInput

final class TranslationServiceTests: XCTestCase {
    func testResponseParserJoinsTextBlocksAndIgnoresOtherBlocks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [
                ["type": "text", "text": "第一段"],
                ["type": "tool_use", "name": "ignored"],
                ["type": "text", "text": "\n第二段"],
            ],
        ])

        XCTAssertEqual(
            try TranslationService.parseResponse(data: data, statusCode: 200),
            "第一段\n第二段"
        )
    }

    func testResponseParserRejectsTruncatedOutput() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "max_tokens",
            "content": [
                ["type": "text", "text": "不完整"],
            ],
        ])

        XCTAssertThrowsError(
            try TranslationService.parseResponse(data: data, statusCode: 200)
        ) { error in
            guard case TranslationService.TranslationError.outputTruncated = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testResponseParserRejectsNonSuccessStatus() throws {
        let body = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"bad request"}}"#.utf8)

        XCTAssertThrowsError(
            try TranslationService.parseResponse(data: body, statusCode: 429)
        ) { error in
            guard case TranslationService.TranslationError.badStatus(let code, let message, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, 429)
            XCTAssertEqual(message, "bad request")
        }
    }

    func testCleanStripsOnlyASingleWrappingQuotePairAddedByTheModel() {
        XCTAssertEqual(
            TranslationService.clean("\u{201C}Hello there.\u{201D}", source: "你好。"),
            "Hello there."
        )
        XCTAssertEqual(
            TranslationService.clean("  \"Ship it.\"\n", source: "发吧。"),
            "Ship it."
        )
    }

    func testCleanKeepsQuotesThatBelongToTheText() {
        // 原文本身以引号开头：结果里的引号是内容，不能剥。
        XCTAssertEqual(
            TranslationService.clean("\"Stay hungry,\" he said.", source: "“保持饥饿，”他说。"),
            "\"Stay hungry,\" he said."
        )
        XCTAssertEqual(
            TranslationService.clean("\u{201C}保持饥饿\u{201D}", source: "\"Stay hungry\""),
            "\u{201C}保持饥饿\u{201D}"
        )
        // 首尾各是不同引用片段，而不是一整段被包裹。
        XCTAssertEqual(
            TranslationService.clean("\"A\" and \"B\"", source: "A 和 B"),
            "\"A\" and \"B\""
        )
        // 只有一侧有引号：不动。
        XCTAssertEqual(
            TranslationService.clean("He said \"yes\"", source: "他说好"),
            "He said \"yes\""
        )
    }
}
