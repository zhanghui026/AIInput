import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 安装主菜单（含 Edit 菜单）。菜单栏 App 默认无主菜单，会导致
        // NSTextField 的 Cmd+C/Cmd+V/Cmd+A 等快捷键失效——Edit 菜单是这些
        // 命令在响应链中的来源。
        installMainMenu()

        // 菜单栏图标
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "character.book.closed",
                                accessibilityDescription: "AI 翻译输入助手")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "显示/关闭输入框（Ctrl+⌥+⌘+E）", action: #selector(trigger), keyEquivalent: "")
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

        // 辅助功能权限引导（注入按键必需）
        promptAccessibilityIfNeeded()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 AI 翻译输入助手", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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

    private func promptAccessibilityIfNeeded() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
        if !trusted {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "需要「辅助功能」权限"
                alert.informativeText = "请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 AIInput，以启用全局热键与文本注入。授权后重启本 App。"
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
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
