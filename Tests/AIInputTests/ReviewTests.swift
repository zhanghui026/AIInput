import XCTest
@testable import AIInput

private func entry(_ surface: String, kind: CardKind = .word, context: String? = nil, gloss: String = "好奇的",
                   pattern: String? = nil, drill: String? = nil, reviews: Int = 0,
                   createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> NotebookEntry {
    var blocks: [CardBlock] = [
        .head(CardHead(lemma: surface, ipa: "/x/", pos: "adj.", level: "B1", label: nil)),
        .senses(CardSenses(items: [CardSense(zh: gloss, pos: nil, tag: "贬", en: "She was curious.", enzh: "她很好奇。", ctx: nil)])),
        .family(CardChips(items: ["observer", "led down"])),
    ]
    if let pattern { blocks.append(.pattern(CardPattern(skeleton: pattern, variants: ["rush to judgment"], drill: drill))) }
    var e = NotebookEntry(kind: kind, key: LookupKey.make(kind: kind, text: surface), surface: surface, context: context,
                          gloss: gloss, pattern: pattern, drill: drill, blocks: blocks, appName: "Safari",
                          createdAt: createdAt, review: .initial(now: createdAt))
    e.reviews = (0..<reviews).map { _ in ReviewEvent(date: createdAt, grade: .good) }
    return e
}

final class ReviewQuestionTests: XCTestCase {
    func testClozeBlanksTheWordInTheOriginalSentenceCaseInsensitively() {
        let e = entry("curious", context: "He was Curious about the noise.")
        let q = ReviewQuestionFactory.make(for: e)
        XCTAssertEqual(q.style, .cloze)
        XCTAssertEqual(q.prompt, "He was _____ about the noise.")
        XCTAssertEqual(q.answer, "curious")
        XCTAssertEqual(q.hint, "好奇的")
        XCTAssertEqual(q.detail, "He was Curious about the noise.")
    }

    func testQuestionStylesRotateAcrossReviews() {
        let styles = (0..<4).map {
            ReviewQuestionFactory.make(for: entry("rush to conclusions", kind: .phrase, context: "Do not rush to conclusions here.",
                                                  gloss: "草率下结论", pattern: "rush to + N", drill: "rush to a ____", reviews: $0)).style
        }
        XCTAssertEqual(styles, [.cloze, .pattern, .recall, .cloze])
    }

    func testWithoutContextOrPatternItFallsBackToRecall() {
        let q = ReviewQuestionFactory.make(for: entry("curious"))
        XCTAssertEqual(q.style, .recall)
        XCTAssertEqual(q.prompt, "好奇的")
        XCTAssertEqual(q.answer, "curious")
    }

    func testNoGlossFallsBackToAskingForTheMeaning() {
        let q = ReviewQuestionFactory.make(for: entry("curious", gloss: ""))
        XCTAssertEqual(q.style, .meaning)
        XCTAssertEqual(q.prompt, "curious")
    }

    func testClozeOnlyBlanksWholeWords() {
        let e = entry("art", context: "The article is about art.")
        XCTAssertEqual(ReviewQuestionFactory.make(for: e).prompt, "The article is about _____.")
        let inside = entry("art", context: "Only an article here.")
        XCTAssertNotEqual(ReviewQuestionFactory.make(for: inside).style, .cloze, "只出现在别的词里面就不出填空")
    }

    func testSentencesNeverGetAClozeOfThemselves() {
        let e = entry("It was simple.", kind: .sentence, context: "It was simple.", gloss: "很简单")
        XCTAssertNotEqual(ReviewQuestionFactory.make(for: e).style, .cloze)
    }
}

@MainActor
final class ReviewSessionTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() -> NotebookStore {
        let store = NotebookStore(fileURL: nil)
        for word in ["alpha", "beta", "gamma"] {
            store.save(target: CardTarget(text: word, kind: .word, context: nil),
                       blocks: [.senses(CardSenses(items: [CardSense(zh: word + "义", pos: nil, tag: nil, en: nil, enzh: nil, ctx: nil)]))],
                       appName: nil, now: created)
        }
        return store
    }

    func testSessionWalksThroughDueEntriesAndSchedulesThem() {
        let store = makeStore()
        let later = created.addingTimeInterval(3 * 86_400)
        let session = ReviewSession(notebook: store)
        session.start(now: later)
        XCTAssertEqual(session.total, 3)
        XCTAssertFalse(session.revealed)

        session.reveal()
        XCTAssertTrue(session.revealed)
        session.grade(.good, now: later)
        XCTAssertFalse(session.revealed, "下一题重新盖住答案")
        session.grade(.good, now: later)
        session.grade(.good, now: later)

        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.graded, 3)
        XCTAssertEqual(session.counts[.good], 3)
        XCTAssertEqual(store.dueCount(now: later), 0)
    }

    func testForgottenEntryComesBackOnceAtTheEnd() {
        let store = makeStore()
        let later = created.addingTimeInterval(3 * 86_400)
        let session = ReviewSession(notebook: store)
        session.start(now: later)
        let first = session.current?.id

        session.grade(.forgot, now: later)
        session.grade(.good, now: later)
        session.grade(.good, now: later)
        XCTAssertEqual(session.current?.id, first, "忘了的排到最后再问一次")
        session.grade(.forgot, now: later)
        XCTAssertTrue(session.isFinished, "每条在一轮里最多重问一次")
        XCTAssertEqual(session.total, 4)
    }

    func testReaskedEntryDoesNotChangeTheScheduleTwice() {
        let store = makeStore()
        let later = created.addingTimeInterval(3 * 86_400)
        let session = ReviewSession(notebook: store)
        session.start(now: later)
        let id = try! XCTUnwrap(session.current?.id)
        session.grade(.forgot, now: later)
        session.grade(.good, now: later)
        session.grade(.good, now: later)
        session.grade(.good, now: later)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(store.entry(forKey: store.entries.first { $0.id == id }!.key)?.reviews.count, 1)
    }

    func testNothingDueFinishesImmediately() {
        let session = ReviewSession(notebook: makeStore())
        session.start(now: created)
        XCTAssertTrue(session.started)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.total, 0)
    }
}

final class LearningStatsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: now)!
    }

    private func record(_ text: String, daysAgo: Int) -> LookupRecord {
        LookupRecord(id: UUID(), key: "w:" + text, text: text, kind: .word, date: day(daysAgo), context: nil, appName: nil)
    }

    func testWeekTotalsNewKeysAndRepeatedLookups() {
        let lookups = [
            record("curious", daysAgo: 0), record("curious", daysAgo: 2), record("curious", daysAgo: 20),
            record("rush", daysAgo: 1), record("old", daysAgo: 40), record("old", daysAgo: 0),
        ]
        var saved = entry("curious")
        saved.createdAt = day(1)
        var reviewed = entry("rush")
        reviewed.createdAt = day(30)
        reviewed.review.interval = 30
        reviewed.reviews = [ReviewEvent(date: day(1), grade: .good), ReviewEvent(date: day(0), grade: .forgot),
                            ReviewEvent(date: day(20), grade: .good)]
        let stats = LearningStats.compute(lookups: lookups, entries: [saved, reviewed], now: now, calendar: calendar)

        XCTAssertEqual(stats.weekLookups, 4)
        XCTAssertEqual(stats.weekNewKeys, 1, "只有 rush 是这一周第一次出现")
        XCTAssertEqual(stats.weekSaved, 1)
        XCTAssertEqual(stats.weekReviews, 2)
        XCTAssertEqual(stats.weekRecallRate, 0.5)
        XCTAssertEqual(stats.mastered, 1)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.days.last?.lookups, 2)
        XCTAssertEqual(stats.repeated.first?.text, "curious")
        XCTAssertEqual(stats.repeated.first?.count, 3)
        XCTAssertEqual(stats.repeated.first?.saved, true, "本子里有同一个 key")
    }

    func testEmptyStats() {
        let stats = LearningStats.compute(lookups: [], entries: [], now: now, calendar: calendar)
        XCTAssertEqual(stats.weekLookups, 0)
        XCTAssertNil(stats.weekRecallRate)
        XCTAssertEqual(stats.days.count, 7)
    }
}

final class NotebookExporterTests: XCTestCase {
    private var items: [NotebookEntry] {
        [entry("curious", context: "He was curious.", pattern: "be curious about", drill: "be ____ about"),
         entry("tab\there", kind: .phrase, context: "A <b>line</b>\nbreak")]
    }

    func testMarkdownGroupsByDayAndIncludesContextAndSections() {
        let md = NotebookExporter.markdown(items)
        XCTAssertTrue(md.contains("## 20"))
        XCTAssertTrue(md.contains("### curious  `/x/ · adj. · B1`"))
        XCTAssertTrue(md.contains("> He was curious."))
        XCTAssertTrue(md.contains("**义项**"))
        XCTAssertTrue(md.contains("1. （贬）好奇的 — She was curious. 她很好奇。"))
        XCTAssertTrue(md.contains("**句型骨架**"))
        XCTAssertTrue(NotebookExporter.markdown([]).contains("还没有内容"))
    }

    func testAnkiTSVHasHeaderOneLinePerEntryAndEscapedFields() {
        let lines = NotebookExporter.ankiTSV(items).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.prefix(4).map(String.init), ["#separator:tab", "#html:true", "#columns:Front\tBack\tTags", "#tags column:3"])
        let rows = lines.dropFirst(4)
        XCTAssertEqual(rows.count, 2)
        for row in rows { XCTAssertEqual(row.split(separator: "\t", omittingEmptySubsequences: false).count, 3, "\(row)") }
        let all = rows.joined(separator: "\n")
        XCTAssertTrue(all.contains("A &lt;b&gt;line&lt;/b&gt;"))
        XCTAssertTrue(all.contains("AIInput::word"))
        XCTAssertTrue(all.contains("AIInput::pattern"))
    }
}
