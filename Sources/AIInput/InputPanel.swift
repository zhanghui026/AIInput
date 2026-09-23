import ApplicationServices
import Cocoa

/// 悬浮 AI 文本面板。
/// 流程：唤起时记录原前台 App/选中文本 → 流式翻译、润色或分析网页 →
/// 预览（可直接修改、⌘R 重来）→ ⌘⏎ 粘贴回原 App 或复制。
/// 点面板外只隐藏并保留现场；Esc 取消并关闭。
@MainActor
final class InputPanel: NSObject {
    static let shared = InputPanel()

    private enum Stage {
        case idle     // 输入中
        case running  // 请求中，结果流式出现
        case preview  // 已有结果，待粘贴/复制
        case failed   // 请求失败，结果区显示错误
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

    /// 点面板外隐藏后，这段时间内再次唤起（且没有新划词）会恢复现场。
    private static let retentionInterval: TimeInterval = 600

    private var panel: NSPanel?
    private let modeControl = NSSegmentedControl()
    private let directionPopUp = NSPopUpButton()
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
    private let regenerateBtn = NSButton()
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
    private var activeRequestID: UUID?
    private var lastSubmittedText = ""
    private var submittedMode: TransformMode = .zhToEnglish
    private var selectionWasCaptured = false
    private var placementSide: PanelPlacement.Side = .below
    private var targetAllowsTextReplacement = true
    private var panelSessionID = UUID()
    private var retainedAt: Date?

    private override init() {}

    private var selectedPanelMode: PanelMode {
        let modes = PanelMode.allCases
        guard modes.indices.contains(modeControl.selectedSegment) else { return .translate }
        return modes[modeControl.selectedSegment]
    }

    private var selectedDirection: TranslationDirection {
        let directions = TranslationDirection.allCases
        guard directions.indices.contains(directionPopUp.indexOfSelectedItem) else { return .auto }
        return directions[directionPopUp.indexOfSelectedItem]
    }

    private var selectedTone: WritingTone {
        let tones = WritingTone.allCases
        guard tones.indices.contains(tonePopUp.indexOfSelectedItem) else { return .faithful }
        return tones[tonePopUp.indexOfSelectedItem]
    }

    /// 按当前选项和输入内容实际会执行的任务。
    private var resolvedMode: TransformMode {
        ModeResolver.resolve(
            panelMode: selectedPanelMode,
            direction: selectedDirection,
            text: inputTextView.string
        )
    }

    private var hasSessionContent: Bool {
        stage != .idle
            || !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        // 记录当前前台 App 和它的 focused element 作为注入目标（排除自己）。
        target = resolveTarget()
        if let t = target {
            Log.flow.notice("show: target=\(t.app.bundleIdentifier ?? "?", privacy: .public) focusedElement=\(t.focusedElement != nil)")
        } else {
            Log.flow.warning("show: 未解析到注入目标")
        }
        targetAllowsTextReplacement = SelectionReader.canReplaceText(in: target?.focusedElement)

        let selection = SelectionReader.selectedText(from: target?.focusedElement)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let retainedRecently = retainedAt.map {
            Date().timeIntervalSince($0) < Self.retentionInterval
        } ?? false
        retainedAt = nil

        if selection == nil, retainedRecently, hasSessionContent {
            // 恢复上次点外面隐藏时的现场；进行中的请求会继续出字。
            Log.flow.notice("show: 恢复上次现场")
            setStage(stage)
            placeNearCursor()
            presentPanel(focus: inputTextView)
            return
        }

        cancelRunningRequest()
        selectionWasCaptured = selection != nil
        inputTextView.string = selection ?? ""
        setResult("")
        if let selection, selectedPanelMode == .webPage, !ModeResolver.isSingleURL(selection) {
            // 划的是普通文字：本次按翻译处理，不改用户保存的偏好。
            selectPanelMode(.translate)
        }
        refreshModeControls()
        updatePlaceholderVisibility()
        setStage(.idle)

        placeNearCursor()
        presentPanel(focus: inputTextView)
        if selection != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.panel?.isVisible == true, self.stage == .idle else { return }
                self.startTransformation()
            }
        }
    }

    /// 点面板外或再按热键：只隐藏，保留输入、结果和进行中的请求。
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
        cancelRunningRequest()
        finishSession()
    }

    /// 结果已粘贴/复制，或用户主动关闭：本轮结束，不再恢复。
    private func finishSession() {
        retainedAt = nil
        panel?.orderOut(nil)
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

        let modes = PanelMode.allCases
        modeControl.segmentCount = modes.count
        for (index, mode) in modes.enumerated() {
            modeControl.setLabel(mode.displayName, forSegment: index)
            modeControl.setToolTip(mode.displayName, forSegment: index)
        }
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = modes.firstIndex(of: Config.panelMode) ?? 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("处理模式")

        let directions = TranslationDirection.allCases
        directionPopUp.addItems(withTitles: directions.map(\.displayName))
        directionPopUp.selectItem(at: directions.firstIndex(of: Config.direction) ?? 0)
        directionPopUp.target = self
        directionPopUp.action = #selector(directionChanged)
        directionPopUp.toolTip = "翻译方向；自动会按输入内容判断"
        directionPopUp.setAccessibilityLabel("翻译方向")

        let tones = WritingTone.allCases
        tonePopUp.addItems(withTitles: tones.map(\.displayName))
        tonePopUp.selectItem(at: tones.firstIndex(of: Config.tone) ?? 0)
        tonePopUp.target = self
        tonePopUp.action = #selector(toneChanged)
        tonePopUp.toolTip = "选择译文或润色结果的写作语气；出结果后切换会立即重写"
        tonePopUp.setAccessibilityLabel("写作语气")

        summaryCheck.title = "包含摘要"
        summaryCheck.setButtonType(.switch)
        summaryCheck.state = Config.includeSummary ? .on : .off
        summaryCheck.target = self
        summaryCheck.action = #selector(summarySettingChanged)
        summaryCheck.setAccessibilityLabel("包含中文摘要")

        let header = NSStackView(views: [modeControl, directionPopUp, tonePopUp, summaryCheck])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.detachesHiddenViews = true
        header.translatesAutoresizingMaskIntoConstraints = false
        tonePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true

        configureTextArea(inputTextView, scroll: inputScroll)
        configureTextArea(resultTextView, scroll: resultScroll)
        inputTextView.delegate = self
        resultTextView.delegate = self
        inputTextView.setAccessibilityLabel("原文")
        resultTextView.setAccessibilityLabel("处理结果")
        resultTextView.isEditable = false
        resultScroll.isHidden = true

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
        copyBtn.toolTip = "复制结果并关闭（⇧⌘C）"
        copyBtn.isHidden = true

        regenerateBtn.title = "重新生成"
        regenerateBtn.bezelStyle = .push
        regenerateBtn.target = self
        regenerateBtn.action = #selector(regenerate)
        regenerateBtn.keyEquivalent = "r"
        regenerateBtn.keyEquivalentModifierMask = [.command]
        regenerateBtn.toolTip = "用当前原文和选项重新生成（⌘R）"
        regenerateBtn.isHidden = true

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

        let bar = NSStackView(views: [hintLabel, spinner, copyBtn, regenerateBtn, actionBtn])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.detachesHiddenViews = true
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
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -pad),
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
    private func configureTextArea(_ textView: NSTextView, scroll: NSScrollView) {
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.insertionPointColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
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

    // MARK: - 模式与选项

    @objc private func modeChanged() {
        Config.panelMode = selectedPanelMode
        selectionWasCaptured = false
        optionsChanged()
    }

    @objc private func directionChanged() {
        Config.direction = selectedDirection
        optionsChanged()
    }

    @objc private func toneChanged() {
        Config.tone = selectedTone
        optionsChanged()
    }

    @objc private func summarySettingChanged() {
        Config.includeSummary = summaryCheck.state == .on
        optionsChanged()
    }

    /// 已有结果时改选项＝按新选项重写；网页任务耗时长，只作废旧结果不自动重跑。
    private func optionsChanged() {
        refreshModeControls()
        switch stage {
        case .idle:
            setStage(.idle)
        case .running, .preview, .failed:
            if resolvedMode == .webPage || submittedMode == .webPage {
                cancelRunningRequest()
                setResult("")
                setStage(.idle)
            } else {
                startTransformation()
            }
        }
    }

    private func selectPanelMode(_ mode: PanelMode) {
        guard let index = PanelMode.allCases.firstIndex(of: mode) else { return }
        modeControl.selectedSegment = index
    }

    private func refreshModeControls() {
        let mode = selectedPanelMode
        directionPopUp.isHidden = mode != .translate
        tonePopUp.isHidden = mode == .webPage
        summaryCheck.isHidden = mode != .webPage
        placeholderLabel.stringValue = placeholder(for: mode)
    }

    private func placeholder(for mode: PanelMode) -> String {
        switch mode {
        case .translate:
            return "输入中文或英文，自动识别方向；也可先在其他 App 选中文字"
        case .polish:
            return "输入要润色的文字"
        case .webPage:
            return "粘贴英文网页链接"
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

    private func directionLabel(for mode: TransformMode) -> String? {
        switch mode {
        case .zhToEnglish: return "中→英"
        case .englishToChinese: return "英→中"
        case .polish, .webPage: return nil
        }
    }

    // MARK: - 状态机

    private func setStage(_ s: Stage, hint: String? = nil, hintIsError: Bool = false) {
        stage = s
        let isWebResult = submittedMode == .webPage
        copyBtn.isHidden = s != .preview || isWebResult
        regenerateBtn.isHidden = s != .preview
        resultTextView.isEditable = s == .preview

        switch s {
        case .idle:
            actionBtn.title = primaryVerb(for: resolvedMode)
            actionBtn.isEnabled = true
            spinner.stopAnimation(nil)
        case .running:
            actionBtn.title = primaryVerb(for: submittedMode)
            actionBtn.isEnabled = false
            spinner.startAnimation(nil)
        case .preview:
            if isWebResult {
                actionBtn.title = "复制全文"
            } else {
                actionBtn.title = canPasteResult ? "粘贴" : "复制"
            }
            actionBtn.isEnabled = true
            spinner.stopAnimation(nil)
        case .failed:
            actionBtn.title = "重试"
            actionBtn.isEnabled = true
            spinner.stopAnimation(nil)
        }
        actionBtn.toolTip = "\(actionBtn.title)（⌘⏎）"
        hintLabel.textColor = hintIsError ? .systemRed : .secondaryLabelColor
        hintLabel.stringValue = hint ?? defaultHint(for: s)
        updateLayout()
    }

    private func defaultHint(for s: Stage) -> String {
        let targetName = target?.app.localizedName
        switch s {
        case .idle:
            let mode = resolvedMode
            if mode == .webPage {
                return "⌘⏎ 分析网页 · 支持无需登录的静态文章页 · Esc 关闭"
            }
            var parts: [String] = []
            if selectionWasCaptured {
                parts.append("已读取选中文本")
            }
            if selectedPanelMode == .translate {
                let inputIsEmpty = inputTextView.string
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if inputIsEmpty, selectedDirection == .auto {
                    parts.append("自动识别方向")
                } else if let label = directionLabel(for: mode) {
                    parts.append(label)
                }
            }
            parts.append("⌘⏎ \(primaryVerb(for: mode))")
            parts.append(targetName.map { "目标：\($0)" } ?? "未检测到目标输入框")
            return parts.joined(separator: " · ")
        case .running:
            if submittedMode == .webPage {
                return "正在提取并翻译网页… Esc 取消"
            }
            let label = directionLabel(for: submittedMode).map { "\($0) " } ?? ""
            return "\(label)\(primaryVerb(for: submittedMode))中… Esc 取消"
        case .preview:
            if submittedMode == .webPage {
                return "⌘⏎ 复制全文 · ⌘R 重新分析 · 可滚动查看"
            }
            let paste = canPasteResult
                ? targetName.map { "⌘⏎ 粘贴到「\($0)」" } ?? "⌘⏎ 粘贴"
                : "⌘⏎ 复制"
            return "\(paste) · ⌘R 重来 · 结果可直接修改"
        case .failed:
            return "⌘⏎ 重试 · 修改原文或选项后再试 · Esc 关闭"
        }
    }

    /// 结果区在预览/失败时显示；请求中收到第一段文字后显示。
    private func updateLayout() {
        let showResult: Bool
        switch stage {
        case .idle: showResult = false
        case .running: showResult = !resultTextView.string.isEmpty
        case .preview, .failed: showResult = true
        }
        barTopIdle?.isActive = false
        barTopPreview?.isActive = false
        (showResult ? barTopPreview : barTopIdle)?.isActive = true
        resultScroll.isHidden = !showResult

        guard let panel = panel else { return }
        let mode = stage == .idle ? resolvedMode : submittedMode
        resultHeightConstraint?.constant = mode == .webPage
            ? Metrics.webResultHeight
            : Metrics.resultHeight
        let height = showResult ? Metrics.previewHeight(for: mode) : Metrics.idleHeight
        guard abs(panel.frame.height - height) > 0.5 || abs(panel.frame.width - Metrics.width) > 0.5 else {
            return
        }
        let frame = PanelPlacement.resizedFrame(
            from: panel.frame,
            to: CGSize(width: Metrics.width, height: height),
            placementSide: placementSide,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        panel.invalidateShadow()
    }

    private func setResult(_ text: String, isError: Bool = false) {
        resultTextView.string = text
        resultTextView.textColor = isError ? .systemRed : .labelColor
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
        case .idle, .failed:
            startTransformation()
        case .running:
            break
        case .preview:
            if canPasteResult {
                pasteResult()
            } else {
                copyResult()
            }
        }
    }

    @objc private func regenerate() {
        startTransformation()
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
        cancelRunningRequest()
        submittedMode = resolvedMode
        guard Config.isConfigured else {
            Log.flow.error("submit: 未配置 API Key/模型")
            showFailure("还没有配置模型服务：请在菜单栏「设置…」中填写 API Key 和模型。")
            return
        }

        lastSubmittedText = text
        let request = TransformationRequest(
            mode: submittedMode,
            tone: selectedTone,
            text: text,
            includeSummary: summaryCheck.state == .on,
            customInstructions: Config.customInstructions
        )
        Log.flow.notice("submit: 开始 \(self.submittedMode.rawValue, privacy: .public)，\(text.count) 字")
        setResult("")
        setStage(.running)

        let requestID = UUID()
        activeRequestID = requestID
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.perform(request) { [weak self] partial in
                    guard let self, self.activeRequestID == requestID else { return }
                    self.showPartial(partial)
                }
                guard self.activeRequestID == requestID, self.stage == .running else { return }
                self.finish(with: result)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    Log.flow.notice("submit: 任务已取消")
                    return
                }
                guard self.activeRequestID == requestID, self.stage == .running else { return }
                self.activeRequestID = nil
                self.translationTask = nil
                Log.flow.error("submit: 处理失败：\(error.localizedDescription, privacy: .public)")
                self.showFailure(error.localizedDescription)
            }
        }
    }

    private func showPartial(_ text: String) {
        let wasEmpty = resultTextView.string.isEmpty
        resultTextView.string = text
        if wasEmpty {
            updateLayout()
        }
        resultTextView.scrollToEndOfDocument(nil)
    }

    private func finish(with result: String) {
        activeRequestID = nil
        translationTask = nil
        Log.flow.notice("submit: 处理成功（\(result.count) 字符）")
        setResult(result)
        if Config.autoPaste,
           submittedMode != .webPage,
           canPasteResult,
           panel?.isVisible == true {
            stage = .preview
            pasteResult()
            return
        }
        setStage(.preview)
        resultTextView.scrollToBeginningOfDocument(nil)
    }

    private func showFailure(_ message: String) {
        setResult(message, isError: true)
        setStage(.failed)
    }

    private func pasteResult() {
        let result = resultTextView.string
        guard !result.isEmpty else { return }
        let injectionSessionID = panelSessionID
        Log.flow.notice("paste: 开始注入")
        finishSession()
        injector.inject(result, into: target) { [weak self] success in
            Log.flow.notice("paste: 注入完成 success=\(success)")
            if !success {
                self?.reshowAfterPasteFailure(
                    result: result,
                    sessionID: injectionSessionID
                )
            }
        }
    }

    private func reshowAfterPasteFailure(result: String, sessionID: UUID) {
        guard panelSessionID == sessionID,
              panel?.isVisible != true,
              let panel else {
            return
        }
        setResult(result)
        setStage(.preview, hint: "未能自动粘贴：结果已保留，可 ⇧⌘C 复制", hintIsError: true)
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
        finishSession()
    }

    private func cancelRunningRequest() {
        guard stage == .running else { return }
        activeRequestID = nil
        translationTask?.cancel()
        translationTask = nil
        Log.flow.notice("submit: 取消进行中的请求")
        setResult("")
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
        // 修改原文使旧结果/进行中的请求失效。
        switch stage {
        case .running:
            cancelRunningRequest()
        case .preview, .failed:
            setResult("")
            setStage(.idle)
        case .idle:
            // 刷新自动识别出的方向和按钮文案。
            setStage(.idle)
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
        // Esc 关闭（处理中先取消）。
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
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
            setStage(.idle)
            return true
        }
        return false
    }
}

// MARK: - 点击面板外：隐藏但保留现场

extension InputPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        dismiss()
    }
}

/// 默认 borderless NSPanel 的 canBecomeKey 为 false，会导致文本框拿不到
/// 键盘焦点、中文输入法不激活。这里重写为 true。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
