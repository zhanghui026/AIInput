import XCTest
@testable import AIInput

final class DroidFallbackTests: XCTestCase {
    func testDroidRunsExecWithOptionalModel() {
        XCTAssertEqual(DroidFallback.arguments(prompt: "P", model: ""), ["exec", "P"])
        XCTAssertEqual(DroidFallback.arguments(prompt: "P", model: " m1 "), ["exec", "-m", "m1", "P"])
    }

    func testCombinedPromptKeepsSystemThenSource() throws {
        let prompt = try TransformationPromptBuilder.make(
            for: TransformationRequest(mode: .zhToEnglish, tone: .faithful, text: "你好")
        )
        let combined = DroidFallback.combine(prompt)
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

    func testProcessRunnerUsesItsOwnEmptyDirectoryAndRemovesIt() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pwd -P; ls -A | wc -l"],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 5
        )
        let lines = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.count, 2)
        // /var 是 /private/var 的符号链接，只比较目录名。
        XCTAssertTrue(URL(fileURLWithPath: lines[0]).lastPathComponent.hasPrefix("AIInput-run-"))
        XCTAssertEqual(lines[1], "0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lines[0]))
    }

    /// 子进程忽略 SIGTERM，且它留下的孙进程一直握着输出管道：仍然要按时返回。
    func testProcessRunnerKillsProcessThatIgnoresTerminate() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 10"],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 0.2,
            killGrace: 0.2,
            drainGrace: 0.2
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// 子进程已退出，但后台孙进程还握着管道：不等它，拿已有输出返回。
    func testProcessRunnerDoesNotWaitForLingeringGrandchild() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10 & echo hi"],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 8,
            drainGrace: 0.3
        )
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
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
        let fallback = StubFallback(result: .failure(DroidFallback.DroidError.notFound))

        do {
            _ = try await makeService(fallback: fallback).perform(
                TransformationRequest(mode: .polish, tone: .faithful, text: "ok")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("API Key 无效或无权限（401）"))
            XCTAssertTrue(error.localizedDescription.contains("备用也失败：找不到 droid 命令"))
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
