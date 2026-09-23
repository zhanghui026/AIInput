import AppKit
import XCTest
@testable import AIInput

final class ClipboardReaderTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("aiinput.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testReadsTrimmedPlainText() {
        pasteboard.setString("  明天见\n", forType: .string)
        XCTAssertEqual(ClipboardReader.text(from: pasteboard), "明天见")
    }

    func testIgnoresEmptyOversizedAndNonTextContent() {
        XCTAssertNil(ClipboardReader.text(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString(" \n ", forType: .string)
        XCTAssertNil(ClipboardReader.text(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString(
            String(repeating: "a", count: ClipboardReader.maximumCharacters + 1),
            forType: .string
        )
        XCTAssertNil(ClipboardReader.text(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)
        XCTAssertNil(ClipboardReader.text(from: pasteboard))
    }

    func testNeverReadsPasswordManagerContent() {
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])

        XCTAssertNil(ClipboardReader.text(from: pasteboard))
    }

    func testSnapshotRestoresEveryItemAndType() {
        let item = NSPasteboardItem()
        item.setString("原文", forType: .string)
        item.setData(Data("<b>原文</b>".utf8), forType: .html)
        pasteboard.writeObjects([item])
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("临时", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "原文")
        XCTAssertEqual(pasteboard.data(forType: .html), Data("<b>原文</b>".utf8))
    }
}
