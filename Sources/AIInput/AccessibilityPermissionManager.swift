import AppKit
import ApplicationServices

/// 辅助功能权限的唯一入口。普通状态查询不会触发系统授权提示。
final class AccessibilityPermissionManager {
    static let shared = AccessibilityPermissionManager()

    private init() {}

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 只能由明确的用户操作调用。
    @discardableResult
    func requestSystemPrompt() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
