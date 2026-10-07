import XCTest
@testable import AIInput

final class FakeCardGenerator: CardGenerating, @unchecked Sendable {
    private let lock = NSLock()
    /// 每次请求依次取一个；空则返回 `defaultOutput`。
    var outputs: [String] = []
    var defaultOutput = ""
    var chunks = 1
    var delay: UInt64 = 0
    var error: Error?
    private(set) var requests: [CardRequest] = []

    func generate(_ request: CardRequest, onPartial: TranslationService.PartialHandler?) async throws -> String {
        let output: String = lock.withLock {
            requests.append(request)
            return outputs.isEmpty ? defaultOutput : outputs.removeFirst()
        }
        let characters = Array(output)
        let size = max(1, characters.count / max(chunks, 1))
        var text = ""
        for start in stride(from: 0, to: characters.count, by: size) {
            text += String(characters[start..<min(start + size, characters.count)])
            await onPartial?(text)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        }
        if let error { throw error }
        return output
    }
}

@MainActor
final class CardModelTests: XCTestCase {
    private let wordCard = """
    {"type":"head","lemma":"curious","ipa":"/ˈkjʊəriəs/","pos":"adj.","level":"B1"}
    {"type":"senses","items":[{"zh":"好奇的","en":"She was curious.","enzh":"她很好奇。"}]}
    {"type":"family","items":["observer","rush to conclusions"]}
    """
    private let phraseCard = """
    {"type":"head","label":"短语 / Phrase"}
    {"type":"trans","literal":"冲向结论","natural":"草率下结论"}
    """

    private var generator: FakeCardGenerator!
    private var preferences: InMemoryPreferences!
    private var notebook: NotebookStore!
    private var lookups: LookupLog!
    private var card: CardModel!

    override func setUp() async throws {
        generator = FakeCardGenerator()
        generator.defaultOutput = wordCard
        preferences = InMemoryPreferences()
        notebook = NotebookStore(fileURL: nil)
        lookups = LookupLog(fileURL: nil)
        card = CardModel(generator: generator, preferences: preferences, notebook: notebook, lookups: lookups)
    }

    func testOpenStreamsBlocksThenBecomesReady() async throws {
        generator.chunks = 6
        card.open(text: "curious", context: "He was curious about it.")
        XCTAssertEqual(card.stage, .loading)
        XCTAssertEqual(card.target?.kind, .word)
        try await waitFor { self.card.stage == .ready }

        XCTAssertEqual(card.blocks.count, 3, "分多次到达的输出每个区块只出现一次")
        XCTAssertEqual(card.blocks.head?.level, "B1")
        XCTAssertEqual(generator.requests.first?.target.context, "He was curious about it.")
    }

    func testBlocksArrivingOutOfOrderAreShownInCardOrder() async throws {
        generator.defaultOutput = """
        {"type":"family","items":["observer"]}
        {"type":"teacher","en":"It means wanting to know."}
        {"type":"head","lemma":"curious","level":"B1"}
        {"type":"senses","items":[{"zh":"好奇的"}]}
        """
        card.open(text: "curious", context: nil)
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(card.blocks.map(\.typeKey), ["head", "senses", "teacher", "family"])
    }

    func testNothingToExplainForChineseText() {
        card.open(text: "好奇", context: nil)
        XCTAssertNil(card.target)
        XCTAssertEqual(card.stage, .idle)
    }

    func testEmptyOutputFailsAndRetryRequestsAgain() async throws {
        generator.outputs = ["Sorry, I cannot help with that."]
        card.open(text: "curious", context: nil)
        try await waitFor { self.card.stage != .loading }
        guard case .failed = card.stage else { return XCTFail("expected failure, got \(card.stage)") }

        card.retry()
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(generator.requests.count, 2)
    }

    func testRequestErrorsAreShown() async throws {
        generator.error = TranslationService.TranslationError.notConfigured
        card.open(text: "curious", context: nil)
        try await waitFor { self.card.stage != .loading }
        XCTAssertEqual(card.stage, .failed(TranslationService.TranslationError.notConfigured.localizedDescription))
    }

    func testChipOpensNestedCardAndPopReturnsToTheCachedPreviousOne() async throws {
        generator.outputs = [wordCard, phraseCard]
        card.open(text: "curious", context: nil)
        try await waitFor { self.card.stage == .ready }

        card.push("rush to conclusions")
        XCTAssertEqual(card.target?.kind, .phrase)
        XCTAssertEqual(card.trail.map(\.text), ["curious"])
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(card.blocks.count, 2)

        card.pop()
        XCTAssertEqual(card.target?.text, "curious")
        XCTAssertEqual(card.stage, .ready, "上一张直接来自缓存")
        XCTAssertEqual(generator.requests.count, 2)
        XCTAssertTrue(card.trail.isEmpty)
    }

    func testChipKeepsTheSentenceAsContextWhenItAppearsInIt() async throws {
        let sentence = "He jumped to conclusions and rush to action."
        card.open(text: sentence, context: nil)
        try await waitFor { self.card.stage != .loading }
        card.push("rush to action")
        XCTAssertEqual(card.target?.context, sentence)
        card.push("unrelated")
        XCTAssertNil(card.target?.context, "不在句子里的 chip 不带上下文")
    }

    func testSlowResultOfAnEarlierCardNeverOverwritesTheCurrentOne() async throws {
        generator.delay = 150_000_000
        generator.chunks = 3
        generator.outputs = [wordCard, phraseCard]
        card.open(text: "curious", context: nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        card.push("rush to conclusions")
        try await waitFor(timeout: 3) { self.card.stage == .ready }

        XCTAssertEqual(card.target?.text, "rush to conclusions")
        XCTAssertEqual(card.blocks.count, 2)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(card.blocks.count, 2)
    }

    func testChangingKindRegeneratesAndIsRemembered() async throws {
        card.open(text: "rush to conclusions", context: nil)
        XCTAssertEqual(card.target?.kind, .phrase)
        try await waitFor { self.card.stage == .ready }

        card.setKind(.sentence)
        XCTAssertEqual(card.target?.kind, .sentence)
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(generator.requests.last?.target.kind, .sentence)

        card.reset()
        card.open(text: "rush to conclusions", context: nil)
        XCTAssertEqual(card.target?.kind, .sentence)
    }

    func testSavingToTheNotebookAndOpeningItAgainNeedsNoRequest() async throws {
        card.appName = "Safari"
        card.open(text: "Curious", context: "He was curious.")
        XCTAssertFalse(card.isSaved)
        try await waitFor { self.card.stage == .ready }

        card.toggleSaved()
        XCTAssertTrue(card.isSaved)
        let saved = try XCTUnwrap(notebook.entries.first)
        XCTAssertEqual(saved.surface, "Curious")
        XCTAssertEqual(saved.context, "He was curious.")
        XCTAssertEqual(saved.gloss, "好奇的")
        XCTAssertEqual(saved.appName, "Safari")

        card.reset()
        card.open(text: "curious", context: nil)
        XCTAssertEqual(card.stage, .ready)
        XCTAssertTrue(card.isSaved)
        XCTAssertEqual(generator.requests.count, 1)

        card.toggleSaved()
        XCTAssertFalse(card.isSaved)
        XCTAssertTrue(notebook.entries.isEmpty)
    }

    func testCannotSaveBeforeTheCardIsReady() {
        card.open(text: "curious", context: nil)
        card.toggleSaved()
        XCTAssertTrue(notebook.entries.isEmpty)
    }

    func testLookupsAreCountedPerLemmaAndRememberEarlierContexts() async throws {
        card.open(text: "rushed", context: "They rushed out.")
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(card.lookupCount, 1)

        card.reset()
        // 同一个词 60 秒内重复打开不重复计数。
        card.open(text: "rush", context: "Do not rush.")
        XCTAssertEqual(card.lookupCount, 1)
    }

    func testLookupLogCanBeSwitchedOff() async throws {
        preferences.lookupLogEnabled = false
        card.open(text: "curious", context: nil)
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(card.lookupCount, 0)
        XCTAssertTrue(lookups.records.isEmpty)
    }

    func testCancelRunningStopsTheRequestAndResumeStartsItAgain() async throws {
        generator.delay = 200_000_000
        generator.chunks = 3
        card.open(text: "curious", context: nil)
        card.cancelRunning()
        XCTAssertEqual(card.stage, .idle)
        XCTAssertTrue(card.blocks.isEmpty)

        generator.delay = 0
        card.resume()
        try await waitFor { self.card.stage == .ready }
        XCTAssertEqual(generator.requests.count, 2)
    }

    private func waitFor(timeout: TimeInterval = 2,
                         _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met; stage=\(card.stage)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
