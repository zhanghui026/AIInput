import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let accessibilityGuideShownKey = "accessibilityGuideShown.v1"

    private var statusItem: NSStatusItem?
    private var accessibilityStatusItem: NSMenuItem?
    private var accessibilityActionItem: NSMenuItem?
    private var settingsController: SettingsWindowController?
    private let accessibilityPermission = AccessibilityPermissionManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 安装主菜单（含 Edit 菜单）。菜单栏 App 默认无主菜单，会导致
        // NSTextField 的 Cmd+C/Cmd+V/Cmd+A 等快捷键失效——Edit 菜单是这些
        // 命令在响应链中的来源。
        installMainMenu()

        // 菜单栏图标
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "character.book.closed",
                                accessibilityDescription: "AIInput")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "显示/关闭输入框（Ctrl+⌥+⌘+E）", action: #selector(trigger), keyEquivalent: "")
        menu.addItem(.separator())

        let permissionStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        permissionStatusItem.isEnabled = false
        menu.addItem(permissionStatusItem)
        accessibilityStatusItem = permissionStatusItem

        let permissionActionItem = NSMenuItem(
            title: "",
            action: #selector(manageAccessibilityPermission),
            keyEquivalent: ""
        )
        permissionActionItem.target = self
        menu.addItem(permissionActionItem)
        accessibilityActionItem = permissionActionItem

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // 全局热键
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(activeAppChanged(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        HotkeyManager.shared.onTrigger = { [weak self] in self?.trigger() }
        if !HotkeyManager.shared.register() {
            promptHotkeyFailure()
        }

        // 辅助功能仅用于读取输入焦点和自动粘贴；状态查询不会触发系统提示。
        let isTrusted = refreshAccessibilityStatus()
        showAccessibilityGuideIfNeeded(isTrusted: isTrusted)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshAccessibilityStatus()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 AIInput", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit 菜单：提供 cut/copy/paste/selectAll，使文本框快捷键生效。
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func trigger() {
        Log.flow.notice("trigger: 热键/菜单触发")
        InputPanel.shared.toggle()
    }

    @objc private func activeAppChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        InputPanel.shared.rememberPotentialTarget(app)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @discardableResult
    private func refreshAccessibilityStatus() -> Bool {
        let isTrusted = accessibilityPermission.isTrusted()
        Log.flow.notice("accessibility: trusted=\(isTrusted)")
        accessibilityStatusItem?.title = isTrusted
            ? "辅助功能：已授权"
            : "辅助功能：未授权（自动粘贴不可用）"
        accessibilityActionItem?.title = isTrusted
            ? "打开辅助功能设置…"
            : "授予辅助功能权限…"
        return isTrusted
    }

    private func showAccessibilityGuideIfNeeded(isTrusted: Bool) {
        guard !isTrusted,
              !UserDefaults.standard.bool(forKey: Self.accessibilityGuideShownKey) else {
            return
        }
        UserDefaults.standard.set(true, forKey: Self.accessibilityGuideShownKey)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let alert = NSAlert()
            alert.messageText = "启用自动粘贴"
            alert.informativeText = "AIInput 只在读取当前输入位置和自动粘贴译文时需要「辅助功能」权限。全局热键无需此权限；你也可以稍后从菜单栏授权。"
            alert.addButton(withTitle: "授权…")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                self.manageAccessibilityPermission()
            }
        }
    }

    @objc private func manageAccessibilityPermission() {
        if !accessibilityPermission.isTrusted() {
            accessibilityPermission.requestSystemPrompt()
        }
        accessibilityPermission.openSystemSettings()
        refreshAccessibilityStatus()
    }

    private func promptHotkeyFailure() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "全局热键注册失败"
            alert.informativeText = "Ctrl+Option+Command+E 可能已被其他 App 占用。你仍可从菜单栏图标打开输入框。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }
}
