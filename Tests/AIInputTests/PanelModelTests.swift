import XCTest
@testable import AIInput

@MainActor
final class PanelModelTests: XCTestCase {
    private var transformer: FakeTransformer!
    private var preferences: InMemoryPreferences!
    private var model: PanelModel!

    override func setUp() async throws {
        transformer = FakeTransformer()
        preferences = InMemoryPreferences()
        model = PanelModel(transformer: transformer, preferences: preferences)
    }

    func testSubmitStreamsPartialsThenStoresAVersion() async throws {
        transformer.partials = ["Hel", "Hello"]
        transformer.results = ["Hello world"]
        model.load(text: "你好世界", origin: .selection)

        model.submit()
        XCTAssertEqual(model.stage, .running)
        try await waitFor { self.model.stage == .preview }

        XCTAssertEqual(model.resultText, "Hello world")
        XCTAssertEqual(model.versions.count, 1)
        XCTAssertEqual(model.submittedMode, .zhToEnglish)
        XCTAssertEqual(transformer.requests.first?.text, "你好世界")
        XCTAssertEqual(transformer.requests.first?.tone, .faithful)
    }

    func testChangingToneAfterAResultRewritesAndKeepsEarlierVersions() async throws {
        transformer.results = ["First", "Second"]
        model.load(text: "你好", origin: .selection)
        model.submit()
        try await waitFor { self.model.stage == .preview }

        model.setTone(.friendly)
        XCTAssertEqual(model.stage, .running)
        try await waitFor { self.model.stage == .preview }

        XCTAssertEqual(model.versions.map(\.text), ["First", "Second"])
        XCTAssertEqual(model.versionIndex, 1)
        XCTAssertEqual(transformer.requests.last?.tone, .friendly)
        XCTAssertEqual(preferences.tone, .friendly)

        model.showVersion(offset: -1)
        XCTAssertEqual(model.resultText, "First")
        model.showVersion(offset: -1)
        XCTAssertEqual(model.versionIndex, 0, "不能越过第一个版本")
    }

    func testChangingOptionsWhileIdleOnlyPersists() {
        model.load(text: "你好", origin: .typed)
        model.setPanelMode(.polish)
        model.setDirection(.englishToChinese)

        XCTAssertEqual(model.stage, .idle)
        XCTAssertTrue(transformer.requests.isEmpty)
        XCTAssertEqual(preferences.panelMode, .polish)
        XCTAssertEqual(preferences.direction, .englishToChinese)
        XCTAssertEqual(model.resolvedMode, .polish)
    }

    func testEditingSourceWhileRunningCancelsAndIgnoresTheLateResult() async throws {
        transformer.delay = 200_000_000
        transformer.results = ["late"]
        model.load(text: "你好", origin: .selection)
        model.submit()

        model.editSource("你好，世界")
        XCTAssertEqual(model.stage, .idle)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(model.stage, .idle)
        XCTAssertTrue(model.versions.isEmpty)
    }

    func testCancelReturnsToThePreviousVersionWhenThereIsOne() async throws {
        transformer.results = ["First", "never"]
        model.load(text: "你好", origin: .selection)
        model.submit()
        try await waitFor { self.model.stage == .preview }

        transformer.delay = 200_000_000
        model.submit()
        model.cancel()

        XCTAssertEqual(model.stage, .preview)
        XCTAssertEqual(model.resultText, "First")
    }

    func testFailureShowsTheErrorAndPrimaryActionRetries() async throws {
        transformer.error = TranslationService.TranslationError.notConfigured
        model.load(text: "你好", origin: .typed)
        model.submit()
        try await waitFor {
            if case .failed = self.model.stage { return true }
            return false
        }

        XCTAssertEqual(model.stage, .failed("未配置 API Key 或模型，请到设置中填写。"))
        XCTAssertEqual(model.primaryAction(), .submit)
    }

    func testPrimaryActionPastesOrCopiesTheEditedResult() async throws {
        transformer.results = ["Hello"]
        model.load(text: "你好", origin: .selection)
        XCTAssertEqual(model.primaryAction(), .submit)
        model.submit()
        XCTAssertEqual(model.primaryAction(), .none)
        try await waitFor { self.model.stage == .preview }

        model.editResult("Hello there")
        model.target = .init(appName: "Notes", canPaste: true, accessibilityTrusted: true)
        XCTAssertEqual(model.primaryAction(), .paste("Hello there"))
        model.target.canPaste = false
        XCTAssertEqual(model.primaryAction(), .copy("Hello there"))
    }

    func testDoesNotSubmitEmptyTextOrWhileComposing() {
        model.load(text: "   ", origin: .typed)
        model.submit()
        XCTAssertEqual(model.stage, .idle)

        model.load(text: "你好", origin: .typed)
        model.isComposing = { true }
        model.submit()
        XCTAssertEqual(model.stage, .idle)
        XCTAssertTrue(transformer.requests.isEmpty)
    }

    func testLoadStartsAFreshSessionAndEmptyTextIsTyped() async throws {
        transformer.results = ["Hello"]
        model.load(text: "你好", origin: .clipboard)
        model.submit()
        try await waitFor { self.model.stage == .preview }

        model.load(text: "", origin: .selection)
        XCTAssertEqual(model.stage, .idle)
        XCTAssertEqual(model.origin, .typed)
        XCTAssertTrue(model.versions.isEmpty)
    }

    func testVisibleTonesKeepTheCurrentToneEvenIfNotAFavorite() {
        XCTAssertEqual(model.visibleTones, Config.defaultFavoriteTones)
        model.setTone(.academic)
        XCTAssertEqual(model.visibleTones, Config.defaultFavoriteTones + [.academic])
        XCTAssertFalse(model.otherTones.contains(.faithful))
        XCTAssertTrue(model.otherTones.contains(.academic))
    }

    func testCustomInstructionsAreSentWithEveryRequest() async throws {
        preferences.customInstructions = "术语：大模型 → LLM"
        model.load(text: "大模型", origin: .typed)
        model.submit()
        try await waitFor { self.model.stage == .preview }
        XCTAssertEqual(transformer.requests.first?.customInstructions, "术语：大模型 → LLM")
    }

    func testRefineRewritesTheCurrentResultAsANewVersion() async throws {
        transformer.results = ["Please join tomorrow's meeting at 3 p.m.", "Meeting at 3 tomorrow."]
        model.load(text: "明天下午三点开会", origin: .selection)
        model.setTone(.professional)
        model.submit()
        try await waitFor { self.model.stage == .preview }

        model.refine(instruction: "更短")
        XCTAssertEqual(model.stage, .running)
        try await waitFor { self.model.stage == .preview }

        let request = try XCTUnwrap(transformer.requests.last)
        XCTAssertEqual(request.refinement, .init(current: "Please join tomorrow's meeting at 3 p.m.", instruction: "更短"))
        XCTAssertEqual(request.tone, .professional)
        XCTAssertEqual(request.text, "明天下午三点开会")
        XCTAssertEqual(model.versions.map(\.text), ["Please join tomorrow's meeting at 3 p.m.", "Meeting at 3 tomorrow."])
        XCTAssertEqual(model.versions.last?.mode, .zhToEnglish)

        model.refine(instruction: "   ")
        XCTAssertEqual(model.stage, .preview, "空指令不发请求")
    }

    private func waitFor(timeout: TimeInterval = 2,
                         _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met; stage=\(model.stage)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class InMemoryPreferences: PanelPreferences {
    var panelMode: PanelMode = .translate
    var direction: TranslationDirection = .auto
    var tone: WritingTone = .faithful
    var favoriteTones: [WritingTone] = Config.defaultFavoriteTones
    var customInstructions = ""
    var historyEnabled = true
    var lookupLogEnabled = true
}

final class FakeTransformer: TextTransforming, @unchecked Sendable {
    private let lock = NSLock()
    var partials: [String] = []
    var results: [String] = []
    var error: Error?
    var delay: UInt64 = 0
    /// 为 true 时按语气返回 "tone:<rawValue>"，便于并行请求的断言。
    var echoTone = false
    private(set) var requests: [TransformationRequest] = []

    func perform(_ request: TransformationRequest,
                 onPartial: TranslationService.PartialHandler?) async throws -> String {
        let result: String = lock.withLock {
            requests.append(request)
            if echoTone { return "tone:\(request.tone.rawValue)" }
            return results.isEmpty ? "result" : results.removeFirst()
        }
        for partial in partials {
            await onPartial?(partial)
        }
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if let error { throw error }
        return result
    }
}
