import ApplicationServices
import Cocoa

/// 悬浮输入面板。弹出时记录原前台 App，输入中文后 Cmd+Return 提交，
/// 译成英文后通过 Injector 粘贴回原 App。
final class InputPanel: NSObject {
    static let shared = InputPanel()

    private var panel: NSPanel?
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let translateBtn = NSButton()
    private let closeBtn = NSButton()

    private let service = TranslationService()
    private let injector = Injector()
    private var target: InjectionTarget?
    private var lastExternalApp: NSRunningApplication?
    private var translating = false

    private override init() {}

    func rememberPotentialTarget(_ app: NSRunningApplication?) {
        guard let app = app, isExternalTarget(app) else { return }
        lastExternalApp = app
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { setup() }

        // 记录当前前台 App 和它的 focused element 作为注入目标（排除自己）。
        target = resolveTarget()

        textView.string = ""
        hintLabel.stringValue = ""
        translateBtn.isEnabled = true
        translating = false
        updatePlaceholderVisibility()

        placeNearCursor()
        // 不激活本 App，避免原 App 的具体输入控件失焦。
        // KeyablePanel + .nonactivatingPanel 仍可接收键盘输入。
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.panel?.makeFirstResponder(self.textView)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func resolveTarget() -> InjectionTarget? {
        if let front = NSWorkspace.shared.frontmostApplication, isExternalTarget(front) {
            lastExternalApp = front
            return InjectionTarget(app: front, focusedElement: currentFocusedElement(for: front))
        }
        guard let last = lastExternalApp, isExternalTarget(last) else {
            lastExternalApp = nil
            return nil
        }
        return InjectionTarget(app: last, focusedElement: currentFocusedElement(for: last))
    }

    private func isExternalTarget(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != "com.apple.systemuiserver",
              !app.isTerminated else {
            return false
        }
        return true
    }

    private func currentFocusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &value) == .success,
              let focused = value else {
            return nil
        }

        let element = focused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == app.processIdentifier else {
            return nil
        }
        return element
    }

    private func setup() {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovable = false
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        self.panel = panel

        let container = NSView()
        panel.contentView = container

        // 多行输入文本框。
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.string = ""

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.stringValue = "输入中文，Cmd+Return 翻译并粘贴，Esc 关闭"
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.isBezeled = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isEditable = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isHidden = false

        translateBtn.title = "翻译"
        translateBtn.bezelStyle = .rounded
        translateBtn.target = self
        translateBtn.action = #selector(submit)
        translateBtn.translatesAutoresizingMaskIntoConstraints = false
        translateBtn.keyEquivalent = "\r"

        closeBtn.bezelStyle = .circular
        closeBtn.title = "×"
        closeBtn.font = .systemFont(ofSize: 14, weight: .bold)
        closeBtn.target = self
        closeBtn.action = #selector(close)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(placeholderLabel)
        container.addSubview(hintLabel)
        container.addSubview(translateBtn)
        container.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeBtn.widthAnchor.constraint(equalToConstant: 22),
            closeBtn.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.heightAnchor.constraint(equalToConstant: 120),

            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 6),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 6),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -6),

            translateBtn.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            translateBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            translateBtn.widthAnchor.constraint(equalToConstant: 70),

            hintLabel.centerYAnchor.constraint(equalTo: translateBtn.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: translateBtn.leadingAnchor, constant: -10),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
    }

    private func placeNearCursor() {
        guard let panel = panel else { return }
        let cursor = NSEvent.mouseLocation
        var frame = panel.frame
        frame.origin = NSPoint(x: cursor.x - frame.width / 2,
                               y: cursor.y - frame.height - 16)
        let screen = NSScreen.screens.first ?? NSScreen.main
        if let scr = screen {
            let visible = scr.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        }
        panel.setFrame(frame, display: true)
    }

    @objc private func close() {
        hide()
    }

    @objc private func submit() {
        guard !translating else { return }
        // 输入法正在组词（有 markedText）时不提交，避免打断。
        if textView.hasMarkedText() { return }

        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if !Config.isConfigured {
            hintLabel.textColor = .systemRed
            hintLabel.stringValue = "请先在菜单栏「设置」中填写 API Key 和模型。"
            return
        }

        translating = true
        translateBtn.isEnabled = false
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = "翻译中…"

        Task {
            do {
                let english = try await service.translate(text)
                await MainActor.run {
                    self.translating = false
                    self.hide()
                    self.injector.inject(english, into: self.target) { success in
                        if !success {
                            self.showInjectionFailure()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.translating = false
                    self.translateBtn.isEnabled = true
                    self.hintLabel.textColor = .systemRed
                    self.hintLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func showInjectionFailure() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "未能粘贴到原输入位置"
            alert.informativeText = "译文已复制到剪贴板。请回到目标输入框后手动粘贴。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    // MARK: - Placeholder

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }
}

extension InputPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Cmd+Return 提交。
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) {
                submit()
                return true
            }
        }
        // Esc 关闭。
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }
}

/// 默认 borderless NSPanel 的 canBecomeKey 为 false，会导致文本框拿不到
/// 键盘焦点、中文输入法不激活。这里重写为 true。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
