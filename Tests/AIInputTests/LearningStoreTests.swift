import XCTest
@testable import AIInput

@MainActor
final class LearningStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiinput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let blocks: [CardBlock] = [
        .senses(CardSenses(items: [CardSense(zh: "好奇的", pos: "adj.", tag: nil, en: nil, enzh: nil, ctx: true)])),
        .pattern(CardPattern(skeleton: "rush to + N", variants: nil, drill: "rush to a ____")),
    ]

    func testNotebookPersistsAndReloadsWithPrivatePermissions() throws {
        let url = directory.appendingPathComponent("notebook.json")
        let store = NotebookStore(fileURL: url)
        let target = CardTarget(text: "curious", kind: .word, context: "He was curious.")
        let saved = store.save(target: target, blocks: blocks, appName: "Safari")
        store.flush()

        let reloaded = NotebookStore(fileURL: url)
        XCTAssertEqual(reloaded.entries, [saved])
        XCTAssertEqual(saved.gloss, "好奇的")
        XCTAssertEqual(saved.pattern, "rush to + N")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
    }

    func testSavingTheSameKeyTwiceKeepsOneEntry() {
        let store = NotebookStore(fileURL: nil)
        let first = store.save(target: CardTarget(text: "rushed", kind: .word, context: nil), blocks: blocks, appName: nil)
        let second = store.save(target: CardTarget(text: "Rush", kind: .word, context: nil), blocks: blocks, appName: nil)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testOneCorruptEntryOrBlockDoesNotLoseTheRest() throws {
        let url = directory.appendingPathComponent("notebook.json")
        let good = NotebookEntry.make(target: CardTarget(text: "curious", kind: .word, context: nil),
                                      blocks: blocks, appName: nil, now: Date())
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let badBlock = goodJSON.replacingOccurrences(of: "\"blocks\":[", with: "\"blocks\":[{\"type\":\"senses\"},")
        let file = #"{"schemaVersion":1,"items":[\#(goodJSON),{"kind":"word"},\#(badBlock)]}"#
        try file.write(to: url, atomically: true, encoding: .utf8)

        let store = NotebookStore(fileURL: url)
        XCTAssertEqual(store.entries.count, 2, "缺必填字段的整条跳过")
        XCTAssertEqual(store.entries.last?.blocks.count, 2, "坏掉的区块被丢掉，其余保留")
    }

    func testReviewMovesTheDueDateAndKeepsAHistory() {
        let store = NotebookStore(fileURL: nil)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = store.save(target: CardTarget(text: "curious", kind: .word, context: nil),
                               blocks: blocks, appName: nil, now: created)
        XCTAssertEqual(store.dueCount(now: created), 0, "刚收进来不用马上复习")
        let tomorrow = created.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.dueEntries(now: tomorrow).map(\.id), [entry.id])

        store.recordReview(id: entry.id, grade: .good, now: tomorrow)
        XCTAssertEqual(store.dueCount(now: tomorrow), 0)
        XCTAssertEqual(store.entries.first?.reviews.map(\.grade), [.good])
        XCTAssertEqual(store.entries.first?.review.repetitions, 1)
    }

    func testLookupLogCountsDedupesAndRemembersContexts() {
        let log = LookupLog(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CardTarget(text: "rushed", kind: .word, context: "They rushed out.")
        let second = CardTarget(text: "rush", kind: .word, context: "Do not rush.")
        let key = LookupKey.make(kind: .word, text: "rush")

        XCTAssertEqual(log.record(target: first, appName: nil, now: now), 1)
        XCTAssertEqual(log.record(target: first, appName: nil, now: now.addingTimeInterval(5)), 1, "60 秒内不重复计")
        XCTAssertEqual(log.earlierContexts(forKey: key, excluding: second.context), ["They rushed out."])
        XCTAssertEqual(log.record(target: second, appName: nil, now: now.addingTimeInterval(3_600)), 2)
        XCTAssertEqual(log.earlierContexts(forKey: key, excluding: "Do not rush."), ["They rushed out."])
    }

    func testLookupLogIsCappedAndClearable() {
        let log = LookupLog(fileURL: nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(LookupLog.limit + 20) {
            _ = log.record(target: CardTarget(text: "word\(index)", kind: .phrase, context: nil),
                           appName: nil, now: start.addingTimeInterval(Double(index) * 120))
        }
        XCTAssertEqual(log.records.count, LookupLog.limit)
        XCTAssertEqual(log.records.first?.text, "word\(LookupLog.limit + 19)")
        log.clear()
        XCTAssertTrue(log.records.isEmpty)
    }
}

final class ReviewSchedulerTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGoodAnswersGrowTheIntervalOneThreeThenByEase() {
        var state = ReviewState.initial(now: now, calendar: calendar)
        state = ReviewScheduler.next(state, grade: .good, now: now, calendar: calendar)
        XCTAssertEqual(state.interval, 1)
        state = ReviewScheduler.next(state, grade: .good, now: now, calendar: calendar)
        XCTAssertEqual(state.interval, 3)
        state = ReviewScheduler.next(state, grade: .good, now: now, calendar: calendar)
        XCTAssertEqual(state.interval, 8, "3 × 2.5 四舍五入")
        XCTAssertEqual(state.repetitions, 3)
        XCTAssertEqual(state.due, ReviewScheduler.day(after: 8, from: now, calendar: calendar))
    }

    func testForgettingResetsProgressAndLowersEaseWithAFloor() {
        var state = ReviewState(due: now, interval: 20, ease: 1.35, repetitions: 5, lapses: 0)
        state = ReviewScheduler.next(state, grade: .forgot, now: now, calendar: calendar)
        XCTAssertEqual(state.repetitions, 0)
        XCTAssertEqual(state.interval, 1)
        XCTAssertEqual(state.lapses, 1)
        XCTAssertEqual(state.ease, ReviewScheduler.minimumEase)
    }

    func testFuzzyGrowsSlightlyWithoutCountingAsRepetition() {
        let state = ReviewState(due: now, interval: 10, ease: 2.5, repetitions: 3, lapses: 0)
        let next = ReviewScheduler.next(state, grade: .fuzzy, now: now, calendar: calendar)
        XCTAssertEqual(next.interval, 12)
        XCTAssertEqual(next.repetitions, 3)
        XCTAssertEqual(next.ease, 2.35, accuracy: 0.0001)
    }

    func testDueDateFallsOnTheStartOfADay() {
        let next = ReviewScheduler.next(.initial(now: now, calendar: calendar), grade: .good, now: now, calendar: calendar)
        XCTAssertEqual(next.due, calendar.startOfDay(for: next.due))
    }
}
