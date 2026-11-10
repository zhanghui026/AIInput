import AppKit
import Carbon.HIToolbox
import XCTest
@testable import AIInput

final class HotkeyTests: XCTestCase {
    func testDefaultHotkeyIsControlOptionCommandE() {
        XCTAssertEqual(Hotkey.default.keyCode, UInt32(kVK_ANSI_E))
        XCTAssertEqual(Hotkey.default.displayString, "⌃⌥⌘E")
    }

    func testBuildsFromAKeyEventAndRequiresAModifier() {
        let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_T), modifierFlags: [.command, .shift])
        XCTAssertEqual(hotkey?.displayString, "⇧⌘T")
        XCTAssertEqual(hotkey?.carbonModifiers, UInt32(cmdKey | shiftKey))

        XCTAssertNil(Hotkey(keyCode: UInt32(kVK_ANSI_T), modifierFlags: []), "裸按键不能当全局热键")
        XCTAssertNil(Hotkey(keyCode: UInt32(kVK_ANSI_T), modifierFlags: [.shift]), "只有 ⇧ 会和打字冲突")
        XCTAssertNotNil(Hotkey(keyCode: UInt32(kVK_Space), modifierFlags: [.option]))
    }

    func testDisplayNamesForSpecialKeys() {
        XCTAssertEqual(Hotkey(keyCode: UInt32(kVK_Space), modifierFlags: [.control])?.displayString, "⌃Space")
        XCTAssertEqual(Hotkey(keyCode: UInt32(kVK_F5), modifierFlags: [.command])?.displayString, "⌘F5")
        XCTAssertEqual(Hotkey(keyCode: UInt32(kVK_ANSI_Semicolon), modifierFlags: [.option])?.displayString, "⌥;")
    }
}

final class FavoriteTonePickerTests: XCTestCase {
    func testTogglingKeepsCanonicalOrderAndAtMostFive() {
        var favorites: [WritingTone] = [.faithful, .concise]
        favorites = FavoriteTones.toggle(.academic, in: favorites)
        XCTAssertEqual(favorites, [.faithful, .concise, .academic])

        favorites = FavoriteTones.toggle(.concise, in: favorites)
        XCTAssertEqual(favorites, [.faithful, .academic])

        favorites = [.faithful, .concise, .professional, .natural, .friendly]
        XCTAssertEqual(FavoriteTones.toggle(.academic, in: favorites), favorites, "满 5 个时不再添加")
        XCTAssertFalse(FavoriteTones.canAdd(to: favorites))
    }

    func testCannotRemoveTheLastFavorite() {
        XCTAssertEqual(FavoriteTones.toggle(.faithful, in: [.faithful]), [.faithful])
    }
}

final class BackupKeyMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "AIInputTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMovesOldKeysToTheNewNames() {
        defaults.set(true, forKey: "droidFallbackEnabled")
        defaults.set("m1", forKey: "fallbackModel")

        Config.migrateLegacyBackupKeys(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: "backupEnabled"))
        XCTAssertEqual(defaults.string(forKey: "backupModel"), "m1")
        XCTAssertNil(defaults.object(forKey: "droidFallbackEnabled"))
        XCTAssertNil(defaults.object(forKey: "fallbackModel"))
    }

    func testKeepsValuesAlreadySavedUnderTheNewNames() {
        defaults.set(true, forKey: "droidFallbackEnabled")
        defaults.set(false, forKey: "backupEnabled")

        Config.migrateLegacyBackupKeys(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: "backupEnabled"))
        XCTAssertNil(defaults.object(forKey: "droidFallbackEnabled"))
    }

    func testDoesNothingWithoutOldKeys() {
        Config.migrateLegacyBackupKeys(in: defaults)
        XCTAssertNil(defaults.object(forKey: "backupEnabled"))
        XCTAssertNil(defaults.object(forKey: "backupModel"))
    }
}
