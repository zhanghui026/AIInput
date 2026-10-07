import XCTest
@testable import AIInput

@MainActor
final class PanelCardTests: XCTestCase {
    private var transformer: FakeTransformer!
    private var generator: FakeCardGenerator!
    private var model: PanelModel!

    override func setUp() async throws {
        transformer = FakeTransformer()
        generator = FakeCardGenerator()
        generator.defaultOutput = #"{"type":"family","items":["observer"]}"#
        model = PanelModel(transformer: transformer, preferences: InMemoryPreferences(), cardGenerator: generator)
    }

    func testCardOnlyForEnglishSelections() {
        model.load(text: "curious", origin: .selection)
        XCTAssertTrue(model.canShowCard)
        XCTAssertEqual(model.cardKind, .word)
        model.load(text: "好奇", origin: .selection)
        XCTAssertFalse(model.canShowCard)
        model.toggleCard()
        XCTAssertEqual(model.viewMode, .single)
    }

    func testTogglingTheCardKeepsTheTranslationAndPassesContext() async throws {
        transformer.results = ["好奇的"]
        model.load(text: "curious", origin: .selection, context: "He was curious.")
        model.submit()
        try await waitFor { self.model.stage == .preview }

        model.toggleCard()
        XCTAssertEqual(model.viewMode, .card)
        XCTAssertEqual(model.card.target?.context, "He was curious.")
        XCTAssertEqual(model.primaryAction(), .closeCard)
        try await waitFor { self.model.card.stage == .ready }

        model.toggleCard()
        XCTAssertEqual(model.viewMode, .single)
        XCTAssertEqual(model.resultText, "好奇的", "回到翻译，结果还在")

        model.toggleCard()
        XCTAssertEqual(generator.requests.count, 1, "再次打开沿用已有的卡片")
    }

    func testEditingOrReloadingTheSourceDropsTheCard() {
        model.load(text: "curious", origin: .selection, context: "He was curious.")
        model.toggleCard()
        model.editSource("curiosity")
        XCTAssertEqual(model.viewMode, .single)
        XCTAssertNil(model.card.target)
        XCTAssertNil(model.sourceContext)
    }

    func testSwitchingToPolishOrToneViewLeavesTheCard() {
        model.load(text: "rush to conclusions", origin: .selection)
        model.toggleCard()
        model.setPanelMode(.polish)
        XCTAssertEqual(model.viewMode, .single)

        model.setPanelMode(.translate)
        model.toggleCard()
        model.toggleToneView()
        XCTAssertEqual(model.viewMode, .tones)
        XCTAssertEqual(model.card.stage, .idle, "离开时停掉还没完成的请求")
    }

    private func waitFor(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
