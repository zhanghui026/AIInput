import Cocoa
import SwiftUI

/// 设置窗口：模型服务、快捷键、常用语气、个人要求、使用习惯。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings = SettingsModel()
    private let applyHotkey: (Hotkey) -> Bool

    init(applyHotkey: @escaping (Hotkey) -> Bool) {
        self.applyHotkey = applyHotkey
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AIInput 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = SettingsView(
            settings: settings,
            history: InputPanel.shared.history,
            lookups: LearningStores.shared.lookups,
            onResetPosition: { [weak self] in
                Config.clearPinnedPanelOrigins()
                self?.settings.notice = "面板位置已重置"
            },
            onCancel: { [weak self] in self?.window?.close() },
            onSave: { [weak self] in self?.save() }
        )
        let hosting = NSHostingController(rootView: view)
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        settings.load()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func save() {
        guard settings.save(applyHotkey: applyHotkey) else { return }
        Log.flow.notice("settings: 已保存")
        window?.close()
    }
}
