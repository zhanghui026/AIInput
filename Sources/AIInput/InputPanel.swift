import ApplicationServices
import Cocoa
import SwiftUI

/// 悬浮面板的外壳：记录目标 App、读取原文（选中文字 → 剪贴板）、摆放窗口、
/// 粘贴或复制结果。交互状态全部在 `PanelModel`，界面在 `PanelView`。
/// 点面板外只隐藏并保留现场；Esc 取消并关闭。
@MainActor
final class InputPanel: NSObject {
    static let shared = InputPanel()

    /// 点面板外隐藏后，这段时间内再次唤起（且没有新内容）会恢复现场。
    private static let retentionInterval: TimeInterval = 600
    private static let cornerRadius: CGFloat = 24

    private var panel: KeyablePanel?
    private var hostingView: SizeReportingHostingView?
    private let model: PanelModel = {
        let service = TranslationService()
        return PanelModel(
            transformer: service,
            preferences: ConfigPreferences(),
            history: HistoryStore(),
            cardGenerator: service,
            notebook: LearningStores.shared.notebook,
            lookups: LearningStores.shared.lookups
        )
    }()
    private let injector = Injector()
    private weak var sourceEditor: NSTextView?

    private var target: InjectionTarget?
    private var lastExternalApp: NSRunningApplication?
    private var targetAllowsTextReplacement = true
    private var accessibilityTrusted = true
    private var panelSessionID = UUID()
    private var retainedAt: Date?
    private var captureTask: Task<Void, Never>?
    /// 上次看过剪贴板时的 changeCount；之后有变化＝用户新复制了内容。
    private var seenClipboardChangeCount = NSPasteboard.general.changeCount
    private var placementSide: PanelPlacement.Side = .below
    private var contentHeight: CGFloat = 0
    /// 选中文字/光标的位置，面板贴在它下方；取不到时用屏幕上方居中。
    private var anchorRect: CGRect?
    private var targetWindowFrame: CGRect?
    /// 区分我们自己调整窗口与用户拖动（只有后者会被记住）。
    private var isApplyingFrame = false

    /// 原文来源（选中文字 / 剪贴板）及是否为新内容。
    private struct Capture {
        let text: String
        let origin: PanelModel.Origin
        /// 选中文字，或上次唤起后新复制到剪贴板的内容。
        let isFresh: Bool
        /// 选中的单词/词组所在的整句，词卡用。
        var context: String?
    }

    private override init() {
        super.init()
        model.isComposing = { [weak self] in
            self?.sourceEditor?.hasMarkedText() ?? false
        }
        model.onResultReady = { [weak self] text in
            guard let self, Config.autoPaste, self.model.target.canPaste,
                  self.panel?.isVisible == true else { return }
            self.paste(text)
        }
    }

    /// 设置页用来显示条数和清空。
    var history: HistoryStore { model.history }

    /// App 启动时调用：此前已在剪贴板里的内容不算“新复制”，不会被自动处理。
    func recordClipboardBaseline() {
        seenClipboardChangeCount = NSPasteboard.general.changeCount
    }

    func rememberPotentialTarget(_ app: NSRunningApplication?) {
        guard let app = app, isExternalTarget(app) else { return }
        lastExternalApp = app
    }

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { setup() }
        injector.cancelPendingInjection()
        panelSessionID = UUID()
        let sessionID = panelSessionID

        // 记录当前前台 App 和它的 focused element 作为注入目标（排除自己）。
        target = resolveTarget()
        if let t = target {
            Log.flow.notice("show: target=\(t.app.bundleIdentifier ?? "?", privacy: .public) focusedElement=\(t.focusedElement != nil)")
        } else {
            Log.flow.warning("show: 未解析到注入目标")
        }
        accessibilityTrusted = AccessibilityPermissionManager.shared.isTrusted()
        targetAllowsTextReplacement = SelectionReader.canReplaceText(in: target?.focusedElement)
        anchorRect = SelectionReader.textBounds(in: target?.focusedElement)
        targetWindowFrame = target.flatMap { SelectionReader.focusedWindowFrame(of: $0.app) }

        // 读取选区可能要向目标 App 发 ⌘C，必须在面板成为 key window 之前完成。
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let capture = await self.captureInput()
            guard self.panelSessionID == sessionID, !Task.isCancelled else { return }
            self.captureTask = nil
            self.present(with: capture)
        }
    }

    /// 点面板外或再按热键：只隐藏，保留原文、结果和进行中的请求。
    func dismiss() {
        guard panel?.isVisible == true else { return }
        Log.flow.notice("dismiss: 面板隐藏（保留现场）")
        retainedAt = hasSessionContent ? Date() : nil
        panel?.orderOut(nil)
    }

    /// Esc：取消进行中的请求并关闭，下次唤起从空白开始。
    func close() {
        guard panel?.isVisible == true else { return }
        Log.flow.notice("close: 面板关闭")
        model.cancel()
        finishSession()
    }

    /// 结果已粘贴/复制，或用户主动关闭：本轮结束，不再恢复。
    private func finishSession() {
        retainedAt = nil
        panel?.orderOut(nil)
    }

    private var hasSessionContent: Bool {
        model.stage != .idle || model.hasSource
    }

    // MARK: - 读取原文：选中文字 → 剪贴板

    private func captureInput() async -> Capture? {
        let pb = NSPasteboard.general
        let clipboardIsFresh = pb.changeCount != seenClipboardChangeCount
        defer { seenClipboardChangeCount = pb.changeCount }

        if accessibilityTrusted, let target {
            let state = SelectionReader.selectionState(in: target.focusedElement)
            switch state {
            case .text(let text):
                Log.flow.notice("capture: 辅助功能读到选中文字（\(text.count) 字）")
                var context: String?
                if let kind = SelectionClassifier.kind(for: text), kind != .sentence {
                    context = SelectionReader.sentenceContext(in: target.focusedElement, selected: text)
                }
                return Capture(text: text, origin: .selection, isFresh: true, context: context)
            case .none:
                break
            case .unknown:
                if let copied = await SelectionCopier.copySelection() {
                    return Capture(text: copied, origin: .selection, isFresh: true)
                }
            }
        }

        guard let text = ClipboardReader.text(from: pb) else {
            Log.flow.notice("capture: 没有选中文字，剪贴板也没有可用文字")
            return nil
        }
        Log.flow.notice("capture: 使用剪贴板（\(text.count) 字，新内容=\(clipboardIsFresh)）")
        return Capture(text: text, origin: .clipboard, isFresh: clipboardIsFresh)
    }

    private func present(with capture: Capture?) {
        let retainedRecently = retainedAt.map {
            Date().timeIntervalSince($0) < Self.retentionInterval
        } ?? false
        retainedAt = nil
        updateModelTarget()

        // 新选中或新复制的内容开启新一轮；否则优先恢复上次点外面隐藏时的现场。
        let startsNewSession = capture?.isFresh ?? false
        if !startsNewSession, retainedRecently, hasSessionContent {
            Log.flow.notice("show: 恢复上次现场")
        } else {
            model.load(text: capture?.text ?? "", origin: capture?.origin ?? .typed, context: capture?.context)
        }

        placePanel()
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)

        if startsNewSession {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.panel?.isVisible == true, self.model.stage == .idle else { return }
                self.model.submit()
            }
        }
    }

    private func updateModelTarget() {
        model.target = PanelModel.Target(
            appName: target?.app.localizedName,
            canPaste: accessibilityTrusted && target != nil && targetAllowsTextReplacement,
            accessibilityTrusted: accessibilityTrusted
        )
    }

    // MARK: - 目标解析

    private func resolveTarget() -> InjectionTarget? {
        if let front = NSWorkspace.shared.frontmostApplication, isExternalTarget(front) {
            lastExternalApp = front
            return InjectionTarget(app: front, focusedElement: SelectionReader.focusedElement(for: front))
        }
        guard let last = lastExternalApp, isExternalTarget(last) else {
            lastExternalApp = nil
            return nil
        }
        return InjectionTarget(app: last, focusedElement: SelectionReader.focusedElement(for: last))
    }

    private func isExternalTarget(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != "com.apple.systemuiserver",
              !app.isTerminated else {
            return false
        }
        return true
    }

    // MARK: - 窗口

    private func setup() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .canJoinAllApplications,
        ]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        panel.onTab = { [weak self] in self?.model.toggleMode() }
        // 历史列表里的 ↑↓ / ⏎（焦点不在文本框时才会到这里）。
        panel.onListKey = { [weak self] key in
            guard let self, self.model.viewMode == .history else { return false }
            switch key {
            case .up: self.model.moveHistorySelection(offset: -1)
            case .down: self.model.moveHistorySelection(offset: 1)
            case .enter: self.model.loadHistorySelection()
            }
            return true
        }
        self.panel = panel

        let actions = PanelActions(
            primary: { [weak self] in self?.performPrimaryAction() },
            copy: { [weak self] in
                guard let self, self.model.stage == .preview else { return }
                self.model.noteUsed(self.model.resultText)
                self.copy(self.model.resultText)
            },
            close: { [weak self] in self?.close() },
            attachSourceEditor: { [weak self] textView in self?.sourceEditor = textView }
        )
        let hostingView = SizeReportingHostingView(rootView: PanelView(model: model, actions: actions))
        // 只让 SwiftUI 报告理想尺寸，窗口大小由外壳按屏幕可见区域决定。
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.autoresizingMask = [.width, .height]
        hostingView.onIntrinsicSizeChange = { [weak self] size in self?.contentSizeChanged(size) }
        self.hostingView = hostingView

        // macOS 26 使用真正的 Liquid Glass；旧系统回退到原生模糊材质。
        let bounds = NSRect(x: 0, y: 0, width: PanelView.width, height: 220)
        hostingView.frame = bounds
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = hostingView
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(hostingView)
            panel.contentView = effect
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// SwiftUI 内容高度变化时，按面板所在一侧伸缩并保持完全可见。
    private func contentSizeChanged(_ size: CGSize) {
        let height = ceil(size.height)
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard let panel else { return }
        let frame = PanelPlacement.resizedFrame(
            from: panel.frame,
            to: CGSize(width: PanelView.width, height: height),
            placementSide: placementSide,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        setPanelFrame(frame)
        panel.invalidateShadow()
    }

    /// 位置优先级：用户拖动后记住的位置 → 贴在选中文字/光标下方 → 屏幕上方居中。
    private func placePanel() {
        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let ideal = hostingView.intrinsicContentSize
        if ideal.height > 0, ideal.height != NSView.noIntrinsicMetric {
            contentHeight = ceil(ideal.height)
        }
        let size = CGSize(width: PanelView.width, height: max(contentHeight, 120))
        let reference = anchorRect.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? targetWindowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(reference, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let result: PanelPlacement.Result
        let method: String
        if let origin = Config.pinnedPanelOrigin(forDisplay: screen.displayKey) {
            result = PanelPlacement.pinned(topLeft: origin, panelSize: size, visibleFrame: screen.visibleFrame)
            method = "记住的位置"
        } else if let anchorRect {
            result = PanelPlacement.anchored(below: anchorRect, panelSize: size, visibleFrame: screen.visibleFrame)
            method = "贴近文字"
        } else {
            result = PanelPlacement.topCenter(panelSize: size, visibleFrame: screen.visibleFrame)
            method = "屏幕上方居中"
        }
        placementSide = result.side
        setPanelFrame(result.frame)
        Log.flow.notice("place: \(method, privacy: .public) side=\(result.side == .below ? "below" : "above", privacy: .public)")
    }

    private func setPanelFrame(_ frame: CGRect) {
        guard let panel else { return }
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    @objc private func screenParametersChanged() {
        guard let panel, panel.isVisible else { return }
        setPanelFrame(PanelPlacement.fit(
            panel.frame,
            toBestOf: NSScreen.screens.map(\.visibleFrame)
        ))
    }

    // MARK: - 粘贴 / 复制

    private func performPrimaryAction() {
        switch model.primaryAction() {
        case .none:
            break
        case .submit:
            model.submit()
        case .paste(let text):
            model.noteUsed(text)
            paste(text)
        case .copy(let text):
            model.noteUsed(text)
            copy(text)
        case .closeCard:
            model.toggleCard()
        }
    }

    private func paste(_ text: String) {
        let sessionID = panelSessionID
        Log.flow.notice("paste: 开始注入")
        finishSession()
        injector.inject(text, into: target) { [weak self] success in
            Log.flow.notice("paste: 注入完成 success=\(success)")
            guard let self else { return }
            // 注入会改写/恢复剪贴板，这不是用户新复制的内容。
            self.seenClipboardChangeCount = NSPasteboard.general.changeCount
            if !success {
                self.reshowAfterPasteFailure(sessionID: sessionID)
            }
        }
    }

    private func reshowAfterPasteFailure(sessionID: UUID) {
        guard panelSessionID == sessionID, panel?.isVisible != true, let panel else { return }
        model.target.canPaste = false
        model.notice = "未能自动粘贴，结果已保留，可复制后手动粘贴"
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        seenClipboardChangeCount = pb.changeCount
        Log.flow.notice("copy: 结果已复制")
        finishSession()
    }
}

// MARK: - 点击面板外：隐藏但保留现场

extension InputPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        dismiss()
    }

    /// 用户拖动面板：记住这块屏幕上的位置，之后都出现在这里（菜单栏可重置）。
    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, let panel, panel.isVisible, let screen = panel.screen else { return }
        placementSide = .below
        Config.setPinnedPanelOrigin(
            CGPoint(x: panel.frame.minX, y: panel.frame.maxY),
            forDisplay: screen.displayKey
        )
    }
}

private extension NSScreen {
    /// 显示器的稳定标识，用来按屏幕记住面板位置。
    var displayKey: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "\($0.uint32Value)" } ?? localizedName
    }
}

/// SwiftUI 内容的理想尺寸变化时（出字、展开编辑器、切换布局）通知外壳调整窗口。
private final class SizeReportingHostingView: NSHostingView<PanelView> {
    var onIntrinsicSizeChange: ((CGSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onIntrinsicSizeChange?(self.intrinsicContentSize)
        }
    }
}

/// 默认 borderless NSPanel 的 canBecomeKey 为 false，会导致文本框拿不到
/// 键盘焦点、中文输入法不激活。这里重写为 true。焦点不在文本框时，
/// Esc / ⇥ 由面板兜底处理。
private final class KeyablePanel: NSPanel {
    enum ListKey {
        case up
        case down
        case enter
    }

    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?
    /// 返回 true 表示已处理。
    var onListKey: ((ListKey) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 48:
                onTab?()
                return
            case 126 where onListKey?(.up) == true:
                return
            case 125 where onListKey?(.down) == true:
                return
            case 36 where onListKey?(.enter) == true, 76 where onListKey?(.enter) == true:
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
