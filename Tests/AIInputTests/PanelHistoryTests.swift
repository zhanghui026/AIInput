import XCTest
@testable import AIInput

@MainActor
final class PanelHistoryTests: XCTestCase {
    private var transformer: FakeTransformer!
    private var preferences: InMemoryPreferences!
    private var history: HistoryStore!
    private var model: PanelModel!

    override func setUp() async throws {
        transformer = FakeTransformer()
        preferences = InMemoryPreferences()
        history = HistoryStore(fileURL: nil)
        model = PanelModel(transformer: transformer, preferences: preferences, history: history)
    }

    func testUsingAResultRecordsItWithItsModeToneAndApp() async throws {
        transformer.results = ["Hello"]
        model.target = .init(appName: "Notes", canPaste: true, accessibilityTrusted: true)
        model.load(text: "你好", origin: .selection)
        model.submit()
        try await waitFor { self.model.stage == .preview }

        model.noteUsed("Hello there")
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.source, "你好")
        XCTAssertEqual(entry.result, "Hello there")
        XCTAssertEqual(entry.mode, .zhToEnglish)
        XCTAssertEqual(entry.tone, .faithful)
        XCTAssertEqual(entry.appName, "Notes")
    }

    func testNothingIsRecordedWhenHistoryIsOff() {
        preferences.historyEnabled = false
        model.load(text: "你好", origin: .typed)
        model.noteUsed("Hello")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testHistoryViewNavigatesAndPastesTheSelectedEntry() {
        history.record(source: "一", result: "One", mode: .zhToEnglish, tone: .faithful, appName: nil)
        history.record(source: "二", result: "Two", mode: .zhToEnglish, tone: .concise, appName: nil)
        model.target = .init(appName: "Notes", canPaste: true, accessibilityTrusted: true)

        model.toggleHistory()
        XCTAssertEqual(model.viewMode, .history)
        XCTAssertEqual(model.primaryAction(), .paste("Two"))
        model.moveHistorySelection(offset: 1)
        XCTAssertEqual(model.primaryAction(), .paste("One"))
        model.moveHistorySelection(offset: 5)
        XCTAssertEqual(model.historyIndex, 1, "不能越过最后一条")

        model.toggleHistory()
        XCTAssertEqual(model.viewMode, .single)
    }

    func testLoadingAnEntryRestoresItAsAPreview() {
        history.record(source: "We was here", result: "We were here", mode: .polish, tone: .natural, appName: nil)
        model.toggleHistory()
        model.loadHistorySelection()

        XCTAssertEqual(model.viewMode, .single)
        XCTAssertEqual(model.stage, .preview)
        XCTAssertEqual(model.sourceText, "We was here")
        XCTAssertEqual(model.resultText, "We were here")
        XCTAssertEqual(model.submittedMode, .polish)
        XCTAssertNotNil(model.revisionSegments, "润色历史载入后也显示修订痕迹")
    }

    func testEmptyHistoryHasNoPrimaryAction() {
        model.toggleHistory()
        XCTAssertEqual(model.primaryAction(), .none)
        model.loadHistorySelection()
        XCTAssertEqual(model.viewMode, .history)
    }

    private func waitFor(timeout: TimeInterval = 2,
                         _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
