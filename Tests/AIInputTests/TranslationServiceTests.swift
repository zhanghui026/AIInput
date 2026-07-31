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
        let body = Data(#"{"error":"bad request"}"#.utf8)

        XCTAssertThrowsError(
            try TranslationService.parseResponse(data: body, statusCode: 429)
        ) { error in
            guard case TranslationService.TranslationError.badStatus(let code, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, 429)
        }
    }
}
