import XCTest
@testable import AIInput

final class SSEParserTests: XCTestCase {
    func testParsesTextDeltasAndStopAndIgnoresEverythingElse() throws {
        XCTAssertEqual(
            try SSEParser.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            .text("Hi")
        )
        XCTAssertEqual(try SSEParser.parse(line: #"data: {"type":"message_stop"}"#), .stop)
        XCTAssertNil(try SSEParser.parse(line: "event: content_block_delta"))
        XCTAssertNil(try SSEParser.parse(line: #"data: {"type":"ping"}"#))
        XCTAssertNil(try SSEParser.parse(line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
        XCTAssertNil(try SSEParser.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#))
        XCTAssertNil(try SSEParser.parse(line: "data: not json"))
    }

    func testMaxTokensAndErrorEventsThrow() {
        XCTAssertThrowsError(
            try SSEParser.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
        ) { error in
            guard case TranslationService.TranslationError.outputTruncated = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try SSEParser.parse(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        ) { error in
            guard case TranslationService.TranslationError.badStatus(529, "Overloaded", _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testServiceMessageExtractsReadableErrorText() {
        XCTAssertEqual(
            TranslationService.serviceMessage(from: Data(#"{"error":{"message":"invalid api key"}}"#.utf8)),
            "invalid api key"
        )
        XCTAssertEqual(
            TranslationService.serviceMessage(from: Data(#"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#.utf8)),
            "login fail"
        )
        XCTAssertEqual(
            TranslationService.serviceMessage(from: Data(String(repeating: "x", count: 500).utf8)).count,
            200
        )
    }
}

final class StreamingServiceTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testStreamsAccumulatedTextAndReturnsCleanedResult() async throws {
        StubURLProtocol.enqueue(status: 200, body: sse(["\u{201C}Hello", " world\u{201D}"]))
        let service = makeService()
        let partials = PartialRecorder()

        let result = try await service.perform(
            TransformationRequest(mode: .zhToEnglish, tone: .faithful, text: "你好世界"),
            onPartial: { partials.values.append($0) }
        )

        XCTAssertEqual(result, "Hello world")
        XCTAssertEqual(partials.values, ["\u{201C}Hello", "\u{201C}Hello world\u{201D}"])
        let body = try XCTUnwrap(StubURLProtocol.requestBodies.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testRetriesOverloadedResponseBeforeAnyOutput() async throws {
        StubURLProtocol.enqueue(status: 529, body: Data(#"{"error":{"type":"overloaded_error","message":"busy"}}"#.utf8))
        StubURLProtocol.enqueue(status: 200, body: sse(["OK"]))

        let result = try await makeService().perform(
            TransformationRequest(mode: .polish, tone: .faithful, text: "ok")
        )

        XCTAssertEqual(result, "OK")
        XCTAssertEqual(StubURLProtocol.requestBodies.count, 2)
    }

    func testDoesNotRetryNonRetryableStatus() async {
        StubURLProtocol.enqueue(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        StubURLProtocol.enqueue(status: 200, body: sse(["never"]))

        do {
            _ = try await makeService().perform(
                TransformationRequest(mode: .polish, tone: .faithful, text: "ok")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "API Key 无效或无权限（401）：bad key")
        }
        XCTAssertEqual(StubURLProtocol.requestBodies.count, 1)
    }

    func testDoesNotRetryOnceTextHasBeenShown() async {
        StubURLProtocol.enqueue(
            status: 200,
            body: sse(["Half"], terminate: false),
            failAfterBody: URLError(.networkConnectionLost)
        )
        StubURLProtocol.enqueue(status: 200, body: sse(["never"]))

        do {
            _ = try await makeService().perform(
                TransformationRequest(mode: .polish, tone: .faithful, text: "ok"),
                onPartial: { _ in }
            )
            XCTFail("expected failure")
        } catch {
            guard case TranslationService.TranslationError.transport = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(StubURLProtocol.requestBodies.count, 1)
    }

    // MARK: - Helpers

    private func makeService() -> TranslationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TranslationService(
            session: URLSession(configuration: configuration),
            config: { ServiceConfig(apiKey: "test", baseURL: "https://stub.invalid/v1", model: "m") },
            retryDelays: [0.01, 0.01]
        )
    }

    private func sse(_ deltas: [String], terminate: Bool = true) -> Data {
        var lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"content":[]}}"#,
            "",
        ]
        for delta in deltas {
            let payload: [String: Any] = [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": delta],
            ]
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            lines += ["event: content_block_delta", "data: \(json)", ""]
        }
        if terminate {
            lines += [
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "",
                #"data: {"type":"message_stop"}"#, "",
            ]
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

@MainActor
private final class PartialRecorder {
    var values: [String] = []
}

final class StubURLProtocol: URLProtocol {
    private struct Stub {
        let status: Int
        let body: Data
        let failAfterBody: Error?
    }

    private static let lock = NSLock()
    private static var stubs: [Stub] = []
    private(set) static var requestBodies: [Data] = []

    static func enqueue(status: Int, body: Data, failAfterBody: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(Stub(status: status, body: body, failAfterBody: failAfterBody))
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs = []
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub? = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.requestBodies.append(Self.bodyData(of: request))
            return Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        }()
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        if let error = stub.failAfterBody {
            // 真实网络里断流发生在文字到达之后；立即失败会让 AsyncBytes 丢弃已缓冲数据。
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                client?.urlProtocol(self, didFailWithError: error)
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
