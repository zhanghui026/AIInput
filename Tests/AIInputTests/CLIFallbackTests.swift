import XCTest
@testable import AIInput

final class FallbackCLIArgumentsTests: XCTestCase {
    func testCodexRunsReadOnlyEphemeralWithOptionalModel() {
        XCTAssertEqual(
            FallbackCLI.codex.arguments(prompt: "P", model: ""),
            ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never", "P"]
        )
        XCTAssertEqual(
            FallbackCLI.codex.arguments(prompt: "P", model: " gpt-x ").suffix(3),
            ["-m", "gpt-x", "P"]
        )
    }

    func testDroidAndAgyPassModelWithTheirOwnFlags() {
        XCTAssertEqual(FallbackCLI.droid.arguments(prompt: "P", model: ""), ["exec", "P"])
        XCTAssertEqual(FallbackCLI.droid.arguments(prompt: "P", model: "m1"), ["exec", "-m", "m1", "P"])
        XCTAssertEqual(FallbackCLI.agy.arguments(prompt: "P", model: ""), ["-p", "P", "--disable-slash-commands"])
        XCTAssertEqual(
            FallbackCLI.agy.arguments(prompt: "P", model: "m2"),
            ["-p", "P", "--disable-slash-commands", "--model", "m2"]
        )
    }

    func testCombinedPromptKeepsSystemThenSource() throws {
        let prompt = try TransformationPromptBuilder.make(
            for: TransformationRequest(mode: .zhToEnglish, tone: .faithful, text: "你好")
        )
        let combined = CLIFallback.combine(prompt)
        let system = try XCTUnwrap(combined.range(of: prompt.system))
        let user = try XCTUnwrap(combined.range(of: prompt.user))
        XCTAssertLessThan(system.lowerBound, user.lowerBound)
        XCTAssertTrue(combined.contains("Do not run commands"))
    }

    func testLocateFindsExecutableOnPath() {
        let found = ShellEnvironment.locate("sh", in: ["PATH": "/nonexistent:/bin"])
        XCTAssertEqual(found?.path, "/bin/sh")
        XCTAssertNil(ShellEnvironment.locate("sh", in: ["PATH": "/nonexistent"]))
    }

    func testProcessRunnerCollectsOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2; exit 3"],
            environment: [:],
            timeout: 5
        )
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
    }

    func testProcessRunnerStopsAtTimeout() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            environment: [:],
            timeout: 0.2
        )
        XCTAssertTrue(result.timedOut)
    }
}

final class ServiceFallbackTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testFallsBackWhenPrimaryFailsBeforeAnyOutput() async throws {
        StubURLProtocol.enqueue(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        let fallback = StubFallback(result: .success("\u{201C}From CLI\u{201D}"))
        let partials = Recorder()

        let result = try await makeService(fallback: fallback).perform(
            TransformationRequest(mode: .zhToEnglish, tone: .faithful, text: "来自 CLI"),
            onPartial: { partials.values.append($0) }
        )

        XCTAssertEqual(result, "From CLI")
        XCTAssertEqual(partials.values, ["From CLI"])
        XCTAssertEqual(fallback.calls, 1)
    }

    func testFallsBackWhenPrimaryIsNotConfigured() async throws {
        let fallback = StubFallback(result: .success("OK"))
        let service = TranslationService(
            session: stubSession(),
            config: { ServiceConfig(apiKey: "", baseURL: "https://stub.invalid/v1", model: "m") },
            retryDelays: [],
            fallback: fallback
        )

        let result = try await service.perform(TransformationRequest(mode: .polish, tone: .faithful, text: "ok"))

        XCTAssertEqual(result, "OK")
        XCTAssertTrue(StubURLProtocol.requestBodies.isEmpty)
    }

    func testReportsBothErrorsWhenFallbackAlsoFails() async {
        StubURLProtocol.enqueue(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        let fallback = StubFallback(result: .failure(CLIFallback.CLIError.notFound(.codex)))

        do {
            _ = try await makeService(fallback: fallback).perform(
                TransformationRequest(mode: .polish, tone: .faithful, text: "ok")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("API Key 无效或无权限（401）"))
            XCTAssertTrue(error.localizedDescription.contains("备用也失败：找不到 codex 命令"))
        }
    }

    func testDoesNotFallBackOnceTextHasBeenShown() async {
        StubURLProtocol.enqueue(
            status: 200,
            body: Data((#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}"# + "\n\n").utf8),
            failAfterBody: URLError(.networkConnectionLost)
        )
        let fallback = StubFallback(result: .success("never"))

        do {
            _ = try await makeService(fallback: fallback).perform(
                TransformationRequest(mode: .polish, tone: .faithful, text: "ok"),
                onPartial: { _ in }
            )
            XCTFail("expected failure")
        } catch {
            guard case TranslationService.TranslationError.transport = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fallback.calls, 0)
    }

    func testDisabledFallbackReportsPrimaryError() async {
        StubURLProtocol.enqueue(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        let fallback = StubFallback(result: .success("never"), isEnabled: false)

        do {
            _ = try await makeService(fallback: fallback).perform(
                TransformationRequest(mode: .polish, tone: .faithful, text: "ok")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "API Key 无效或无权限（401）：bad key")
        }
        XCTAssertEqual(fallback.calls, 0)
    }

    // MARK: - Helpers

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeService(fallback: TextFallback) -> TranslationService {
        TranslationService(
            session: stubSession(),
            config: { ServiceConfig(apiKey: "test", baseURL: "https://stub.invalid/v1", model: "m") },
            retryDelays: [],
            fallback: fallback
        )
    }
}

@MainActor
private final class Recorder {
    var values: [String] = []
}

private final class StubFallback: TextFallback, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, Error>
    let isEnabled: Bool
    private var count = 0

    init(result: Result<String, Error>, isEnabled: Bool = true) {
        self.result = result
        self.isEnabled = isEnabled
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func run(_ prompt: TransformationPrompt) async throws -> String {
        lock.lock()
        count += 1
        lock.unlock()
        return try result.get()
    }
}
