import ApplicationServices
import AppKit
import CoreGraphics

struct InjectionTarget {
    let app: NSRunningApplication
    let focusedElement: AXUIElement?
}

/// 把英文文本粘贴回原程序光标处：保存原剪贴板 → 写入英文 → 重激活原 App →
/// 模拟 Cmd+V → 延迟后恢复原剪贴板。
final class Injector {
    /// 向 `target` 注入 `text`。
    func inject(_ text: String,
                into target: InjectionTarget?,
                completion: @escaping (Bool) -> Void = { _ in }) {
        let pb = NSPasteboard.general
        let trusted = AccessibilityPermissionManager.shared.isTrusted()
        Log.flow.notice("inject: AXIsProcessTrusted=\(trusted) target=\(target?.app.bundleIdentifier ?? "nil", privacy: .public) focusedElement=\(target?.focusedElement != nil)")
        guard trusted else {
            Log.flow.warning("inject: 未获辅助功能权限，译文仅复制到剪贴板")
            pb.clearContents()
            pb.setString(text, forType: .string)
            completion(false)
            return
        }
        guard let target = target else {
            Log.flow.warning("inject: 无目标，译文仅复制到剪贴板")
            pb.clearContents()
            pb.setString(text, forType: .string)
            completion(false)
            return
        }
        let app = target.app

        let saved = Snapshot.capture(from: pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // 重新激活原 App，让光标焦点回到它身上。
        app.activate(options: [.activateAllWindows])

        // 在后台等待原 App 真正成为前台后再发 Cmd+V，避免粘贴到隐藏的面板里。
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let front = self.waitUntilFrontmost(pid: pid, timeout: 1.5)
            Log.flow.notice("inject: 目标置前 ok=\(front)")
            guard front else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            self.restoreFocus(to: target.focusedElement)
            Thread.sleep(forTimeInterval: 0.12)
            self.restoreFocus(to: target.focusedElement)
            self.postPaste()
            Log.flow.notice("inject: 已发送 Cmd+V")
            // 等粘贴完成再恢复剪贴板。
            Thread.sleep(forTimeInterval: 0.8)
            DispatchQueue.main.async {
                saved.restore(to: pb)
                Log.flow.notice("inject: 剪贴板已恢复")
                completion(true)
            }
        }
    }

    /// 轮询等待目标 App 成为前台，最多等 `timeout` 秒。
    private func waitUntilFrontmost(pid: pid_t, timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if pid != 0,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
    }

    private func restoreFocus(to element: AXUIElement?) {
        guard let element = element else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        // virtualKey 9 = 'V'。
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        cmdDown?.flags = CGEventFlags.maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        cmdUp?.flags = CGEventFlags.maskCommand
        cmdDown?.post(tap: .cgSessionEventTap)
        cmdUp?.post(tap: .cgSessionEventTap)
    }
}

/// 剪贴板快照，用于粘贴后恢复。尽力恢复所有类型；不可读的类型会跳过。
private struct Snapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]

    static func capture(from pb: NSPasteboard) -> Snapshot {
        var collected: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    pairs.append((type, data))
                }
            }
            collected.append(pairs)
        }
        return Snapshot(items: collected)
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(restored)
    }
}
