import XCTest
@testable import AIInput

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiinput-history-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsNewestFirstAndPersistsOwnerOnly() throws {
        let store = HistoryStore(fileURL: fileURL)
        store.record(source: "你好", result: "Hello", mode: .zhToEnglish, tone: .faithful, appName: "Notes")
        store.record(source: "再见", result: "Bye", mode: .zhToEnglish, tone: .concise, appName: nil)

        XCTAssertEqual(store.entries.map(\.result), ["Bye", "Hello"])
        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries, store.entries)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testKeepsOnlyTheMostRecentEntries() {
        let store = HistoryStore(fileURL: fileURL)
        for index in 0..<(HistoryStore.limit + 5) {
            store.record(source: "s\(index)", result: "r\(index)", mode: .polish, tone: .faithful, appName: nil)
        }
        XCTAssertEqual(store.entries.count, HistoryStore.limit)
        XCTAssertEqual(store.entries.first?.result, "r\(HistoryStore.limit + 4)")
    }

    func testUsingTheSameResultAgainMovesItToTheTop() {
        let store = HistoryStore(fileURL: fileURL)
        store.record(source: "a", result: "A", mode: .polish, tone: .faithful, appName: nil)
        store.record(source: "b", result: "B", mode: .polish, tone: .faithful, appName: nil)
        store.record(source: "a", result: "A", mode: .polish, tone: .faithful, appName: "Mail")

        XCTAssertEqual(store.entries.map(\.result), ["A", "B"])
        XCTAssertEqual(store.entries.first?.appName, "Mail")
    }

    func testIgnoresEmptyResultsAndClearRemovesTheFile() {
        let store = HistoryStore(fileURL: fileURL)
        store.record(source: "a", result: "  ", mode: .polish, tone: .faithful, appName: nil)
        XCTAssertTrue(store.entries.isEmpty)

        store.record(source: "a", result: "A", mode: .polish, tone: .faithful, appName: nil)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(HistoryStore(fileURL: fileURL).entries.isEmpty)
    }
}
