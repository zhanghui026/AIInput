import XCTest
@testable import AIInput

final class TextDiffTests: XCTestCase {
    func testWordReplacementsInEnglish() {
        let segments = TextDiff.segments(
            from: "We was planning to shipped it on friday.",
            to: "We were planning to ship it on Friday."
        )
        XCTAssertEqual(segments, [
            .same("We "),
            .removed("was"),
            .inserted("were"),
            .same(" planning to "),
            .removed("shipped"),
            .inserted("ship"),
            .same(" it on "),
            .removed("friday"),
            .inserted("Friday"),
            .same("."),
        ])
        XCTAssertEqual(TextDiff.changeCount(segments), 3)
    }

    func testChineseDiffsByCharacter() {
        let segments = TextDiff.segments(from: "我们明天开会", to: "我们后天开会")
        XCTAssertEqual(segments, [.same("我们"), .removed("明"), .inserted("后"), .same("天开会")])
        XCTAssertEqual(TextDiff.changeCount(segments), 1)
    }

    func testPureInsertionAndDeletion() {
        XCTAssertEqual(
            TextDiff.segments(from: "Ship it.", to: "Ship it today."),
            [.same("Ship it"), .inserted(" today"), .same(".")]
        )
        let inserted = TextDiff.segments(from: "Ship it", to: "Ship it now")
        XCTAssertEqual(inserted.last, .inserted(" now"))
        XCTAssertEqual(TextDiff.text(of: inserted, including: .new), "Ship it now")

        let removed = TextDiff.segments(from: "请务必准时参加", to: "请准时参加")
        XCTAssertEqual(removed, [.same("请"), .removed("务必"), .same("准时参加")])
    }

    func testMixedChineseAndEnglishKeepsBothSidesRecoverable() {
        let old = "请 review 这个 PR，谢谢"
        let new = "请帮忙 review 这个 pull request，谢谢！"
        let segments = TextDiff.segments(from: old, to: new)
        XCTAssertEqual(TextDiff.text(of: segments, including: .old), old)
        XCTAssertEqual(TextDiff.text(of: segments, including: .new), new)
        XCTAssertGreaterThan(TextDiff.changeCount(segments), 0)
    }

    func testIdenticalTextHasNoChanges() {
        let segments = TextDiff.segments(from: "Same text.", to: "Same text.")
        XCTAssertEqual(segments, [.same("Same text.")])
        XCTAssertEqual(TextDiff.changeCount(segments), 0)
    }
}
