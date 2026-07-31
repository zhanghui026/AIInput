import ApplicationServices
import Cocoa

/// 悬浮 AI 文本面板。
/// 流程：唤起时记录原前台 App/选中文本 → 翻译、润色或分析网页 →
/// 面板内预览 → 粘贴回原 App 或复制。Esc 关闭（处理中为取消）。
final class InputPanel: NSObject {
    static let shared = InputPanel()

    private enum Stage {
        case idle        // 输入中，待翻译
        case translating // 请求中
        case preview     // 已有译文，待粘贴
    }

    private enum Metrics {
        static let width: CGFloat = 620
        static let pad: CGFloat = 18
        static let headerHeight: CGFloat = 30
        static let inputHeight: CGFloat = 112
        static let resultHeight: CGFloat = 210
        static let webResultHeight: CGFloat = 330
        static let gap: CGFloat = 12
        static let barHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 24
        static var idleHeight: CGFloat {
            pad + headerHeight + gap + inputHeight + gap + barHeight + pad
        }
        static func previewHeight(for mode: TransformMode) -> CGFloat {
            let result = mode == .webPage ? webResultHeight : resultHeight
            return idleHeight + gap + result
        }
    }

    private var panel: NSPanel?
    private let modeControl = NSSegmentedControl()
    private let tonePopUp = NSPopUpButton()
    private let summaryCheck = NSButton()
    private let inputTextView = NSTextView()
    private let inputScroll = NSScrollView()
    private let resultTextView = NSTextView()
    private let resultScroll = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyBtn = NSButton()
    private let actionBtn = NSButton()
    private var barTopIdle: NSLayoutConstraint?
    private var barTopPreview: NSLayoutConstraint?
    private var resultHeightConstraint: NSLayoutConstraint?

    private let service = TranslationService()
    private let injector = Injector()
    private var target: InjectionTarget?
    private var lastExternalApp: NSRunningApplication?
    private var stage: Stage = .idle
    private var translationTask: Task<Void, Never>?
    private var lastSubmittedText = ""
    private var submittedMode: TransformMode = .zhToEnglish
    private var selectionWasCaptured = false
    private var placementSide: PanelPlacement.Side = .below
    private var targetAllowsTextReplacement = true

    private override init() {}

    private var selectedMode: TransformMode {
        let modes = TransformMode.allCases
        guard modes.indices.contains(modeControl.selectedSegment) else {
            return .zhToEnglish
        }
        return modes[modeControl.selectedSegment]
    }

    private var selectedTone: WritingTone {
        let tones = WritingTone.allCases
        guard tones.indices.contains(tonePopUp.indexOfSelectedItem) else {
            return .faithful
        }
        return tones[tonePopUp.indexOfSelectedItem]
    }

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
        if let t = target {
            Log.flow.notice("show: target=\(t.app.bundleIdentifier ?? "?", privacy: .public) focusedElement=\(t.focusedElement != nil)")
        } else {
            Log.flow.warning("show: 未解析到注入目标")
        }

        var selectedContent: String?
        if let rawSelection = selectedText(from: target?.focusedElement) {
            let trimmed = rawSelection.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                selectedContent = trimmed
            }
        }
        targetAllowsTextReplacement = canReplaceText(in: target?.focusedElement)
        selectionWasCaptured = selectedContent != nil
        inputTextView.string = selectedContent ?? ""
        resultTextView.string = ""
        var shouldTranslateSelection = false
        if let selectedContent,
           let detectedMode = LanguageDirectionDetector.suggestedMode(for: selectedContent) {
            selectMode(detectedMode)
            shouldTranslateSelection = true
        } else {
            refreshModeControls()
        }
        updatePlaceholderVisibility()
        setStage(.idle)

        placeNearCursor()
        presentPanel(focus: inputTextView)
        if shouldTranslateSelection {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.panel?.isVisible == true, self.stage == .idle else { return }
                self.startTransformation()
            }
        }
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        Log.flow.notice("hide: 面板关闭")
        cancelTranslationIfNeeded()
        panel?.orderOut(nil)
    }

    // MARK: - 目标解析

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
              let focused = value,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
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

    private func selectedText(from element: AXUIElement?) -> String? {
        guard let element else { return nil }

        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element,
                                         kAXSubroleAttribute as CFString,
                                         &subroleValue) == .success,
           let subrole = subroleValue as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func canReplaceText(in element: AXUIElement?) -> Bool {
        guard let element else { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success {
            return settable.boolValue
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return true
        }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    // MARK: - UI 搭建

    private func setup() {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0,
                                                     width: Metrics.width,
                                                     height: Metrics.idleHeight),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
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
        self.panel = panel

        // macOS 26 使用真正的 Liquid Glass；旧系统回退到原生模糊材质。
        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = Metrics.cornerRadius
            glass.contentView = content
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: content.frame)
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Metrics.cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            panel.contentView = effect
        }

        let modes = TransformMode.allCases
        modeControl.segmentCount = modes.count
        for (index, mode) in modes.enumerated() {
            modeControl.setLabel(mode.displayName, forSegment: index)
            modeControl.setToolTip(mode.displayName, forSegment: index)
        }
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("处理模式")
        modeControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tonePopUp.addItems(withTitles: WritingTone.allCases.map(\.displayName))
        tonePopUp.selectItem(at: 0)
        tonePopUp.target = self
        tonePopUp.action = #selector(toneChanged)
        tonePopUp.toolTip = "选择译文或润色结果的写作语气"
        tonePopUp.setAccessibilityLabel("写作语气")

        summaryCheck.title = "包含摘要"
        summaryCheck.setButtonType(.switch)
        summaryCheck.state = .on
        summaryCheck.target = self
        summaryCheck.action = #selector(summarySettingChanged)
        summaryCheck.setAccessibilityLabel("包含中文摘要")

        let header = NSStackView(views: [modeControl, tonePopUp, summaryCheck])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.detachesHiddenViews = true
        header.translatesAutoresizingMaskIntoConstraints = false
        tonePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true

        configureTextArea(inputTextView, scroll: inputScroll, editable: true)
        configureTextArea(resultTextView, scroll: resultScroll, editable: false)
        inputTextView.delegate = self
        resultTextView.delegate = self
        inputTextView.setAccessibilityLabel("原文")
        resultTextView.setAccessibilityLabel("处理结果")
        resultScroll.isHidden = true

        placeholderLabel.stringValue = "输入中文"
        placeholderLabel.font = .systemFont(ofSize: 15)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.isBezeled = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isEditable = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        copyBtn.title = "复制"
        copyBtn.bezelStyle = .push
        copyBtn.target = self
        copyBtn.action = #selector(copyResult)
        // ⇧⌘C（⌘C 留给文本框的常规拷贝）。
        copyBtn.keyEquivalent = "c"
        copyBtn.keyEquivalentModifierMask = [.command, .shift]
        copyBtn.isHidden = true

        actionBtn.title = "翻译"
        if #available(macOS 26.0, *) {
            actionBtn.bezelStyle = .glass
        } else {
            actionBtn.bezelStyle = .push
        }
        actionBtn.target = self
        actionBtn.action = #selector(primaryAction)
        // 只在 Cmd+Return 时触发。不能用裸 "\r"：key equivalent 在事件到达
        // first responder / 输入法之前分发，裸 Return 会被按钮拦截，导致
        // 无法输入换行、组词时按回车也无法上屏。
        actionBtn.keyEquivalent = "\r"
        actionBtn.keyEquivalentModifierMask = [.command]

        let bar = NSStackView(views: [hintLabel, spinner, copyBtn, actionBtn])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(inputScroll)
        content.addSubview(resultScroll)
        content.addSubview(placeholderLabel)
        content.addSubview(bar)

        let pad = Metrics.pad
        barTopIdle = bar.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: Metrics.gap)
        barTopPreview = bar.topAnchor.constraint(equalTo: resultScroll.bottomAnchor, constant: Metrics.gap)
        resultHeightConstraint = resultScroll.heightAnchor.constraint(equalToConstant: Metrics.resultHeight)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.headerHeight),

            inputScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.gap),
            inputScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            inputScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            inputScroll.heightAnchor.constraint(equalToConstant: Metrics.inputHeight),

            resultScroll.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: Metrics.gap),
            resultScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            resultScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            resultHeightConstraint!,

            // placeholder 与文本首行对齐（containerInset 6 + lineFragmentPadding 5）。
            placeholderLabel.topAnchor.constraint(equalTo: inputScroll.topAnchor, constant: 6),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor, constant: 11),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: inputScroll.trailingAnchor, constant: -6),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.barHeight),
            barTopIdle!,
        ])
        refreshModeControls()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// 输入/结果区共用样式：透明滚动容器 + 轻底色圆角。
    private func configureTextArea(_ textView: NSTextView, scroll: NSScrollView, editable: Bool) {
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.insertionPointColor = .labelColor
        textView.isEditable = editable
        textView.isSelectable = true
        textView.allowsUndo = editable
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.borderWidth = 0.5
        scroll.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - 模式与语气

    @objc private func modeChanged() {
        selectionWasCaptured = false
        resetResultForOptionChange()
        refreshModeControls()
    }

    @objc private func toneChanged() {
        resetResultForOptionChange()
    }

    @objc private func summarySettingChanged() {
        resetResultForOptionChange()
    }

    private func selectMode(_ mode: TransformMode) {
        guard let index = TransformMode.allCases.firstIndex(of: mode) else { return }
        modeControl.selectedSegment = index
        refreshModeControls()
    }

    private func refreshModeControls() {
        let isWeb = selectedMode == .webPage
        tonePopUp.isHidden = isWeb
        summaryCheck.isHidden = !isWeb
        resultHeightConstraint?.constant = isWeb ? Metrics.webResultHeight : Metrics.resultHeight
        placeholderLabel.stringValue = placeholder(for: selectedMode)
        actionBtn.toolTip = "\(primaryVerb(for: selectedMode))（⌘⏎）"
        if stage == .idle {
            actionBtn.title = primaryVerb(for: selectedMode)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.stringValue = defaultHint(for: .idle)
        }
    }

    private func placeholder(for mode: TransformMode) -> String {
        switch mode {
        case .zhToEnglish:
            return "输入中文，或先在其他 App 选中中文"
        case .englishToChinese:
            return "输入英文，或先在其他 App 划词"
        case .polish:
            return "输入要润色的文字"
        case .webPage:
            return "粘贴英文网页链接（https://…）"
        }
    }

    private func primaryVerb(for mode: TransformMode) -> String {
        switch mode {
        case .zhToEnglish, .englishToChinese:
            return "翻译"
        case .polish:
            return "润色"
        case .webPage:
            return "分析"
        }
    }

    private func resetResultForOptionChange() {
        if stage == .translating {
            translationTask?.cancel()
            translationTask = nil
        }
        resultTextView.string = ""
        if stage != .idle {
            setStage(.idle)
        }
    }

    // MARK: - 状态机

    private func setStage(_ s: Stage, hint: String? = nil, hintIsError: Bool = false) {
        stage = s
        let showResult = (s == .preview)
        barTopIdle?.isActive = false
        barTopPreview?.isActive = false
        (showResult ? barTopPreview : barTopIdle)?.isActive = true
        resultScroll.isHidden = !showResult
        copyBtn.isHidden = !showResult

        switch s {
        case .idle:
            actionBtn.title = primaryVerb(for: selectedMode)
            actionBtn.isEnabled = true
            spinner.stopAnimation(nil)
        case .translating:
            actionBtn.title = primaryVerb(for: submittedMode)
            actionBtn.isEnabled = false
            spinner.startAnimation(nil)
        case .preview:
            if submittedMode == .webPage {
                actionBtn.title = "复制全文"
            } else {
                actionBtn.title = canPasteResult ? "粘贴" : "复制"
            }
            actionBtn.isEnabled = true
            spinner.stopAnimation(nil)
        }
        hintLabel.textColor = hintIsError ? .systemRed : .secondaryLabelColor
        hintLabel.stringValue = hint ?? defaultHint(for: s)
        resizePanel(for: s)
    }

    private func defaultHint(for s: Stage) -> String {
        let targetName = target?.app.localizedName
        switch s {
        case .idle:
            if selectedMode == .webPage {
                return "⌘⏎ 分析网页 · 支持无需登录的静态文章页 · Esc 关闭"
            }
            let dest = targetName.map { "目标：\($0)" } ?? "未检测到目标输入框"
            let selection = selectionWasCaptured ? "已读取选中文本 · " : ""
            return "\(selection)⌘⏎ \(primaryVerb(for: selectedMode)) · Esc 关闭 · \(dest)"
        case .translating:
            return submittedMode == .webPage ? "正在提取并翻译网页… Esc 取消" : "处理中… Esc 取消"
        case .preview:
            if submittedMode == .webPage {
                return "⌘⏎ 复制全文 · ⇧⌘C 复制 · 可滚动查看"
            }
            let dest = canPasteResult
                ? targetName.map { "⌘⏎ 粘贴到「\($0)」" } ?? "⌘⏎ 粘贴"
                : "⌘⏎ 复制结果"
            return "\(dest) · ⇧⌘C 复制"
        }
    }

    private func resizePanel(for s: Stage) {
        guard let panel = panel else { return }
        let mode = s == .preview ? submittedMode : selectedMode
        resultHeightConstraint?.constant = mode == .webPage
            ? Metrics.webResultHeight
            : Metrics.resultHeight
        let height = s == .preview ? Metrics.previewHeight(for: mode) : Metrics.idleHeight
        let frame = PanelPlacement.resizedFrame(
            from: panel.frame,
            to: CGSize(width: Metrics.width, height: height),
            placementSide: placementSide,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        panel.invalidateShadow()
    }

    // MARK: - 呈现

    private func presentPanel(focus: NSView?) {
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let focus = focus else { return }
            self.panel?.makeFirstResponder(focus)
        }
    }

    private func placeNearCursor() {
        guard let panel = panel else { return }
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let result = PanelPlacement.nearCursor(
            cursor: cursor,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        placementSide = result.side
        panel.setFrame(result.frame, display: true)
    }

    @objc private func screenParametersChanged() {
        guard let panel, panel.isVisible else { return }
        let frame = PanelPlacement.fit(
            panel.frame,
            toBestOf: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: - 动作

    @objc private func primaryAction() {
        switch stage {
        case .idle: startTransformation()
        case .translating: break
        case .preview:
            if !canPasteResult {
                copyResult()
            } else {
                pasteResult()
            }
        }
    }

    private var canPasteResult: Bool {
        submittedMode != .webPage && target != nil && targetAllowsTextReplacement
    }

    private func startTransformation() {
        // 输入法正在组词（有 markedText）时不提交，避免打断。
        if inputTextView.hasMarkedText() {
            Log.flow.notice("submit: 被 markedText 拦截（输入法组词中）")
            return
        }
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Log.flow.notice("submit: 文本为空")
            return
        }
        guard Config.isConfigured else {
            Log.flow.error("submit: 未配置 API Key/模型")
            setStage(.idle, hint: "请先在菜单栏「设置」中填写 API Key 和模型。", hintIsError: true)
            return
        }

        lastSubmittedText = text
        submittedMode = selectedMode
        let request = TransformationRequest(
            mode: submittedMode,
            tone: selectedTone,
            text: text,
            includeSummary: summaryCheck.state == .on
        )
        Log.flow.notice("submit: 开始 \(self.primaryVerb(for: self.submittedMode), privacy: .public)，\(text.count) 字")
        setStage(.translating)

        translationTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await self.service.perform(request)
                try Task.checkCancellation()
                await MainActor.run {
                    self.translationTask = nil
                    guard self.stage == .translating else { return }
                    Log.flow.notice("submit: 处理成功（\(result.count) 字符），进入预览")
                    self.resultTextView.string = result
                    self.setStage(.preview)
                }
            } catch {
                if Task.isCancelled {
                    Log.flow.notice("submit: 任务已取消")
                    return
                }
                await MainActor.run {
                    self.translationTask = nil
                    guard self.stage == .translating else { return }
                    Log.flow.error("submit: 翻译失败：\(error.localizedDescription, privacy: .public)")
                    self.setStage(.idle, hint: error.localizedDescription, hintIsError: true)
                }
            }
        }
    }

    private func pasteResult() {
        let result = resultTextView.string
        guard !result.isEmpty else { return }
        Log.flow.notice("paste: 开始注入")
        hide()
        injector.inject(result, into: target) { [weak self] success in
            Log.flow.notice("paste: 注入完成 success=\(success)")
            if !success {
                self?.reshowAfterPasteFailure()
            }
        }
    }

    private func reshowAfterPasteFailure() {
        guard let panel = panel else { return }
        setStage(.preview, hint: "未能自动粘贴：译文已保留，可 ⇧⌘C 复制", hintIsError: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func copyResult() {
        let result = resultTextView.string
        guard !result.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(result, forType: .string)
        Log.flow.notice("copy: 结果已复制")
        hide()
    }

    private func cancelTranslationIfNeeded() {
        guard stage == .translating else { return }
        translationTask?.cancel()
        translationTask = nil
        Log.flow.notice("submit: 取消进行中的翻译")
        setStage(.idle)
    }

    // MARK: - Placeholder

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !inputTextView.string.isEmpty
    }
}

// MARK: - 文本框事件

extension InputPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inputTextView else { return }
        selectionWasCaptured = false
        updatePlaceholderVisibility()
        // 修改原文使旧译文/进行中的请求失效。
        switch stage {
        case .translating:
            cancelTranslationIfNeeded()
        case .preview:
            resultTextView.string = ""
            setStage(.idle)
        case .idle:
            break
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Cmd+Return 提交。正常情况下按钮的 key equivalent 会先拦截；
        // 此处兜底（如按钮被禁用时事件落回文本框）。
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags
                .intersection(.deviceIndependentFlagsMask) ?? []
            if flags.contains(.command) {
                Log.flow.notice("doCommandBy: Cmd+Return 兜底触发")
                primaryAction()
                return true
            }
            // 普通 Return 交回系统默认处理：组词时由输入法上屏，
            // 否则插入换行。
            return false
        }
        // Esc 关闭（翻译中先取消）。
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        // 空输入时 ↑ 恢复上次原文。
        if commandSelector == #selector(NSResponder.moveUp(_:)),
           textView === inputTextView,
           stage == .idle,
           inputTextView.string.isEmpty,
           !lastSubmittedText.isEmpty {
            inputTextView.string = lastSubmittedText
            inputTextView.setSelectedRange(NSRange(location: lastSubmittedText.utf16.count, length: 0))
            updatePlaceholderVisibility()
            return true
        }
        return false
    }
}

// MARK: - 点击面板外自动关闭

extension InputPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        hide()
    }
}

/// 默认 borderless NSPanel 的 canBecomeKey 为 false，会导致文本框拿不到
/// 键盘焦点、中文输入法不激活。这里重写为 true。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
