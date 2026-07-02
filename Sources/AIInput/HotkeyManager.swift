import Carbon.HIToolbox
import Cocoa

/// 全局热键管理。用 Carbon RegisterEventHotKey 注册 Ctrl+Option+Cmd+E。
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// 注册成功返回 true。
    @discardableResult
    func register() -> Bool {
        if hotKeyRef != nil { return true }

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
        guard status == noErr else { return false }

        let id = EventHotKeyID(signature: fourCharCode("AIIN"), id: hotkeyId)
        // keyCode 14 = 'E'；修饰键 control+option+command。
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let regStatus = RegisterEventHotKey(14, mods, id,
                                            GetApplicationEventTarget(),
                                            0,
                                            &hotKeyRef)
        if regStatus != noErr {
            if let handler = eventHandler {
                RemoveEventHandler(handler)
                eventHandler = nil
            }
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
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
