import ApplicationServices
import AppKit
import CoreGraphics

struct InjectionTarget {
    let app: NSRunningApplication
    let focusedElement: AXUIElement?
}

/// 把英文文本粘贴回原程序光标处：保存原剪贴板 → 写入英文 → 重激活原 App →
/// 模拟 Cmd+V → 延迟后恢复原剪贴板。
@MainActor
final class Injector {
    private var injectionTask: Task<Void, Never>?
    private var injectionID: UUID?
    private var pendingSnapshot: PasteboardSnapshot?
    private var injectedPasteboardChangeCount: Int?

    /// 向 `target` 注入 `text`。目标里若仍有选区，粘贴即替换选区。
    func inject(_ text: String,
                into target: InjectionTarget?,
                completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        cancelPendingInjection()
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

        let saved = PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let currentInjectionID = UUID()
        injectionID = currentInjectionID
        pendingSnapshot = saved
        injectedPasteboardChangeCount = pb.changeCount

        // 重新激活原 App，让光标焦点回到它身上。
        app.activate(options: [.activateAllWindows])

        // 异步等待原 App 真正成为前台后再发 Cmd+V，避免粘贴到隐藏的面板里。
        let pid = app.processIdentifier
        injectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let front = try await self.waitUntilFrontmost(pid: pid, timeout: 1.5)
                try Task.checkCancellation()
                guard self.injectionID == currentInjectionID else { return }
                Log.flow.notice("inject: 目标置前 ok=\(front)")
                guard front else {
                    self.clearPendingInjection(id: currentInjectionID)
                    completion(false)
                    return
                }

                self.restoreFocus(to: target.focusedElement)
                try await Task.sleep(nanoseconds: 120_000_000)
                guard self.injectionID == currentInjectionID else { return }
                self.restoreFocus(to: target.focusedElement)
                KeyboardEvents.postCommand(KeyboardEvents.keyCodeV)
                Log.flow.notice("inject: 已发送 Cmd+V")

                // 仅当剪贴板仍是本次注入值时恢复，避免覆盖用户刚复制的新内容。
                try await Task.sleep(nanoseconds: 800_000_000)
                guard self.injectionID == currentInjectionID else { return }
                self.restorePendingClipboardIfUnchanged()
                self.clearPendingInjection(id: currentInjectionID)
                completion(true)
            } catch is CancellationError {
                // cancelPendingInjection 已同步处理剪贴板和状态。
            } catch {
                guard self.injectionID == currentInjectionID else { return }
                self.clearPendingInjection(id: currentInjectionID)
                completion(false)
            }
        }
    }

    /// 新面板会话开始前停止旧注入，防止旧任务抢焦点、粘贴或覆盖剪贴板。
    func cancelPendingInjection() {
        injectionTask?.cancel()
        injectionTask = nil
        injectionID = nil
        restorePendingClipboardIfUnchanged()
        pendingSnapshot = nil
        injectedPasteboardChangeCount = nil
    }

    /// 轮询等待目标 App 成为前台，最多等 `timeout` 秒。
    private func waitUntilFrontmost(pid: pid_t, timeout: TimeInterval) async throws -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            if pid != 0,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    private func restorePendingClipboardIfUnchanged() {
        guard let pendingSnapshot,
              let injectedPasteboardChangeCount else {
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == injectedPasteboardChangeCount else {
            Log.flow.notice("inject: 剪贴板已被其他操作修改，跳过恢复")
            return
        }
        pendingSnapshot.restore(to: pasteboard)
        Log.flow.notice("inject: 剪贴板已恢复")
    }

    private func clearPendingInjection(id: UUID) {
        guard injectionID == id else { return }
        injectionTask = nil
        injectionID = nil
        pendingSnapshot = nil
        injectedPasteboardChangeCount = nil
    }

    private func restoreFocus(to element: AXUIElement?) {
        guard let element = element else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}
