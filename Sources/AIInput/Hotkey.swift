import AppKit
import Carbon.HIToolbox

/// 全局热键：虚拟键码 + Carbon 修饰键。
struct Hotkey: Equatable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let `default` = Hotkey(
        keyCode: UInt32(kVK_ANSI_E),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 从录制到的按键构造；至少要有 ⌘、⌥ 或 ⌃ 之一，否则会和正常打字冲突。
    init?(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: keyCode, carbonModifiers: UInt32(modifiers))
    }

    /// 按 macOS 习惯的顺序显示：⌃⌥⇧⌘ + 键名。
    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeys[Int(keyCode)] { return name }
        if let character = ansiCharacters[Int(keyCode)] { return character }
        return "Key\(keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let ansiCharacters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}

/// 常用语气（⌘1–⌘5）的选择规则：保持固定顺序，最多 5 个，至少 1 个。
enum FavoriteTones {
    static let limit = 5

    static func canAdd(to favorites: [WritingTone]) -> Bool {
        favorites.count < limit
    }

    static func toggle(_ tone: WritingTone, in favorites: [WritingTone]) -> [WritingTone] {
        var set = Set(favorites)
        if set.contains(tone) {
            guard set.count > 1 else { return favorites }
            set.remove(tone)
        } else {
            guard canAdd(to: favorites) else { return favorites }
            set.insert(tone)
        }
        return WritingTone.allCases.filter(set.contains)
    }
}
