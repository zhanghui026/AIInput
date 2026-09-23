import Carbon.HIToolbox
import Cocoa

/// 全局热键管理。用 Carbon RegisterEventHotKey 注册，热键可在设置里修改（默认 ⌃⌥⌘E）。
final class HotkeyManager: @unchecked Sendable {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    private(set) var current: Hotkey?

    /// 注册成功返回 true；已有热键会先注销，失败时不保留任何热键。
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            current = nil
        }
        let id = EventHotKeyID(signature: fourCharCode("AIIN"), id: hotkeyId)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyRef = nil
            return false
        }
        current = hotkey
        return true
    }

    private func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        // kEventHotKeyPressed：按键按下时触发。
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef = eventRef, let userData = userData else { return noErr }
                let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let size = MemoryLayout<EventHotKeyID>.size
                GetEventParameter(eventRef,
                                  UInt32(kEventParamDirectObject),
                                  UInt32(typeEventHotKeyID),
                                  nil,
                                  size,
                                  nil,
                                  &hkID)
                if hkID.id == me.hotkeyId {
                    DispatchQueue.main.async {
                        me.onTrigger?()
                    }
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
        return status == noErr
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            current = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    var onTrigger: (() -> Void)?

    private let hotkeyId: UInt32 = 1

    private func fourCharCode(_ s: String) -> OSType {
        var result: OSType = 0
        for ch in s.utf8 {
            result = (result << 8) | OSType(ch)
        }
        return result
    }
}
