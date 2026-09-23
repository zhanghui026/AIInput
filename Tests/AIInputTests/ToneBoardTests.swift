import XCTest
@testable import AIInput

@MainActor
final class ToneBoardTests: XCTestCase {
    private var transformer: FakeTransformer!
    private var preferences: InMemoryPreferences!
    private var model: PanelModel!

    override func setUp() async throws {
        transformer = FakeTransformer()
        transformer.echoTone = true
        preferences = InMemoryPreferences()
        model = PanelModel(transformer: transformer, preferences: preferences)
        model.load(text: "明天下午三点开会", origin: .selection)
    }

    func testToneGroupsCoverEveryToneAndFavoritesUseTheFirstFour() {
        let favorites = Config.defaultFavoriteTones
        XCTAssertEqual(ToneGroup.favorites.tones(favorites: favorites), Array(favorites.prefix(4)))
        let fixed = ToneGroup.allCases.filter { $0 != .favorites }
            .flatMap { $0.tones(favorites: favorites) }
        XCTAssertEqual(Set(fixed), Set(WritingTone.allCases))
        XCTAssertEqual(fixed.count, WritingTone.allCases.count, "固定分组之间不重复")
    }

    func testOpeningTheViewGeneratesTheVisibleGroupInParallel() async throws {
        model.toggleToneView()
        XCTAssertEqual(model.viewMode, .tones)
        try await waitForCards(4)

        let board = model.toneBoard
        XCTAssertEqual(Set(transformer.requests.map(\.tone)), Set(ToneGroup.favorites.tones(favorites: Config.defaultFavoriteTones)))
        XCTAssertTrue(transformer.requests.allSatisfy { $0.mode == .zhToEnglish && $0.text == "明天下午三点开会" })
        XCTAssertEqual(board.cards[.concise], .done("tone:concise"))
        XCTAssertEqual(board.chosen, .faithful, "默认选中当前语气")
    }

    func testSwitchingTabsOnlyRequestsTonesWithoutResults() async throws {
        model.toggleToneView()
        try await waitForCards(4)
        model.toneBoard.selectGroup(.everyday)
        try await waitForCards(6)
        model.toneBoard.selectGroup(.favorites)
        model.toneBoard.selectGroup(.everyday)
        try await Task.sleep(nanoseconds: 50_000_000)

        // 常用 = 忠实 简洁 专业 自然；日常 = 自然 友好 口语 简洁，只需补 友好、口语。
        XCTAssertEqual(transformer.requests.count, 6)
        XCTAssertEqual(Set(transformer.requests.suffix(2).map(\.tone)), [.friendly, .conversational])
    }

    func testChoosingACardDrivesThePrimaryAction() async throws {
        model.target = .init(appName: "Slack", canPaste: true, accessibilityTrusted: true)
        model.toggleToneView()
        try await waitForCards(4)

        model.toneBoard.choose(index: 1)
        XCTAssertEqual(model.toneBoard.chosen, .concise)
        XCTAssertEqual(model.primaryAction(), .paste("tone:concise"))
    }

    func testLeavingTheViewAdoptsTheChosenCardAsANewVersion() async throws {
        model.toggleToneView()
        try await waitForCards(4)
        model.toneBoard.choose(.professional)

        model.toggleToneView()
        XCTAssertEqual(model.viewMode, .single)
        XCTAssertEqual(model.stage, .preview)
        XCTAssertEqual(model.tone, .professional)
        XCTAssertEqual(preferences.tone, .professional)
        XCTAssertEqual(model.resultText, "tone:professional")
    }

    func testEditingTheSourceOrModeInvalidatesTheBoard() async throws {
        model.toggleToneView()
        try await waitForCards(4)

        model.setDirection(.englishToChinese)
        try await waitForCards(4)
        XCTAssertTrue(transformer.requests.suffix(4).allSatisfy { $0.mode == .englishToChinese })

        model.setPanelMode(.polish)
        XCTAssertEqual(model.viewMode, .single, "润色没有多语气视图")
        XCTAssertTrue(model.toneBoard.cards.isEmpty)
    }

    func testTheViewNeedsSourceTextAndTranslateMode() {
        model.load(text: "", origin: .typed)
        model.toggleToneView()
        XCTAssertEqual(model.viewMode, .single)

        model.load(text: "你好", origin: .typed)
        model.setPanelMode(.polish)
        model.toggleToneView()
        XCTAssertEqual(model.viewMode, .single)
    }

    func testFailedCardCanBeRetriedOnItsOwn() async throws {
        transformer.error = TranslationService.TranslationError.notConfigured
        model.toggleToneView()
        try await waitFor { self.model.toneBoard.cards.values.allSatisfy { if case .failed = $0 { return true }; return false } && self.model.toneBoard.cards.count == 4 }

        transformer.error = nil
        model.toneBoard.retry(.natural)
        try await waitFor { self.model.toneBoard.cards[.natural] == .done("tone:natural") }
        XCTAssertEqual(transformer.requests.count, 5)
    }

    private func waitForCards(_ count: Int) async throws {
        try await waitFor {
            self.model.toneBoard.cards.values.filter { if case .done = $0 { return true }; return false }.count >= count
        }
    }

    private func waitFor(timeout: TimeInterval = 2,
                         _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met; cards=\(model.toneBoard.cards)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
