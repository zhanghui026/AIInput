import AppKit
import SwiftUI

/// 面板字体：结果用衬线阅读体，界面用圆体，按键用等宽键帽。
enum Typography {
    /// New York，中文回落到宋体，读起来像排好版的正文。
    static func result(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let songti = NSFontDescriptor(fontAttributes: [.name: "Songti SC"])
        return NSFont(descriptor: serif.addingAttributes([.cascadeList: [songti]]), size: size) ?? base
    }

    static func source(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let keycap = Font.system(size: 10.5, weight: .medium, design: .monospaced)
}

/// 面板里需要外壳（窗口、粘贴、剪贴板）完成的动作。
struct PanelActions {
    var primary: () -> Void
    var copy: () -> Void
    var close: () -> Void
    var attachSourceEditor: (NSTextView) -> Void
}

struct PanelView: View {
    static let width: CGFloat = 680

    @ObservedObject var model: PanelModel
    @ObservedObject var toneBoard: ToneBoard
    let actions: PanelActions

    init(model: PanelModel, actions: PanelActions) {
        self.model = model
        self.toneBoard = model.toneBoard
        self.actions = actions
    }

    @State private var editingSource = false
    @State private var sourceHeight: CGFloat = 56
    @State private var resultHeight: CGFloat = 28
    @State private var refining = false
    @State private var refineText = ""
    @FocusState private var refineFieldFocused: Bool

    private var showsEditor: Bool {
        model.viewMode == .single && (model.stage == .idle || editingSource)
    }

    private var inToneView: Bool {
        model.viewMode == .tones
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if !inToneView {
                if refining, model.stage == .preview {
                    refineRow
                } else {
                    toneRow
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.stage) { stage in
            if stage == .running {
                editingSource = false
                refining = false
                refineText = ""
            }
        }
    }

    // MARK: - 头部：来源 · 方向 …… 版本 · 翻译⇄润色

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: originIcon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(originLabel)
                .font(Typography.ui(12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if model.panelMode == .translate {
                directionMenu
            }
            Spacer(minLength: 8)
            if model.versions.count > 1, !inToneView {
                versionStepper
            }
            if model.panelMode == .translate {
                viewSwitch
            }
            modeToggle
        }
    }

    private var originIcon: String {
        switch model.origin {
        case .selection: return "text.quote"
        case .clipboard: return "doc.on.clipboard"
        case .typed: return "keyboard"
        }
    }

    private var originLabel: String {
        let app = model.target.appName
        switch model.origin {
        case .selection: return "来自 \(app ?? "当前 App") 的选中文字"
        case .clipboard: return "来自剪贴板"
        case .typed: return app.map { "写给 \($0)" } ?? "直接输入"
        }
    }

    private var directionMenu: some View {
        Menu {
            ForEach(TranslationDirection.allCases, id: \.self) { direction in
                Button {
                    model.setDirection(direction)
                } label: {
                    if direction == model.direction {
                        Label(direction.displayName, systemImage: "checkmark")
                    } else {
                        Text(direction.displayName)
                    }
                }
            }
        } label: {
            Text("· \(directionText)")
                .font(Typography.ui(12))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("翻译方向")
    }

    private var directionText: String {
        let arrow = model.resolvedMode == .englishToChinese ? "EN → 中" : "中 → EN"
        return model.direction == .auto ? "\(arrow)（自动）" : arrow
    }

    private var versionStepper: some View {
        HStack(spacing: 2) {
            Button { model.showVersion(offset: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("上一版")
            .disabled(model.versionIndex == 0)
            Text("\(model.versionIndex + 1)/\(model.versions.count)")
                .font(Typography.ui(12).monospacedDigit())
            Button { model.showVersion(offset: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut("]", modifiers: .command)
            .accessibilityLabel("下一版")
            .disabled(model.versionIndex == model.versions.count - 1)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.trailing, 6)
        .help("切换版本（⌘[ / ⌘]）")
    }

    private var viewSwitch: some View {
        Button(action: model.toggleToneView) {
            HStack(spacing: 6) {
                Text("单个")
                    .fontWeight(inToneView ? .regular : .semibold)
                    .foregroundColor(inToneView ? .secondary : .primary)
                Text("多语气")
                    .fontWeight(inToneView ? .semibold : .regular)
                    .foregroundColor(inToneView ? .primary : .secondary)
                Keycap("⌘K")
            }
            .font(Typography.ui(12.5))
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .disabled(!model.canShowToneView && !inToneView)
        .help("同时查看多个语气的译文（⌘K）")
    }

    private var modeToggle: some View {
        let isTranslate = model.panelMode == .translate
        return Button(action: model.toggleMode) {
            HStack(spacing: 6) {
                Text("翻译")
                    .fontWeight(isTranslate ? .semibold : .regular)
                    .foregroundColor(isTranslate ? .primary : .secondary)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("润色")
                    .fontWeight(isTranslate ? .regular : .semibold)
                    .foregroundColor(isTranslate ? .secondary : .primary)
                Keycap("⇥")
            }
            .font(Typography.ui(12.5))
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("切换翻译 / 润色（⇥）")
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        if inToneView {
            VStack(alignment: .leading, spacing: 12) {
                sourceQuote
                ToneBoardView(board: toneBoard)
            }
        } else if showsEditor {
            sourceEditor
        } else if model.submittedMode == .polish {
            // 润色：左原文、右结果，逐句对照。
            HStack(alignment: .top, spacing: 20) {
                Text(model.sourceText)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { editingSource = true }
                    .help("点击编辑原文")
                resultArea
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                sourceQuote
                resultArea
            }
        }
    }

    private var sourceEditor: some View {
        GrowingTextView(
            text: model.sourceText,
            font: Typography.source(size: 16),
            placeholder: model.panelMode == .translate
                ? "输入要翻译的文字，中英文自动识别"
                : "输入要润色的文字",
            minHeight: 56,
            maxHeight: 220,
            autoFocus: true,
            selectAllOnFocus: model.origin == .clipboard,
            height: $sourceHeight,
            onChange: model.editSource,
            onCommand: handle,
            onAttach: actions.attachSourceEditor
        )
        .frame(height: sourceHeight)
    }

    private var sourceQuote: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 2)
            Text(model.sourceText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { editingSource = true }
        .help("点击编辑原文")
    }

    @ViewBuilder
    private var resultArea: some View {
        switch model.stage {
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14))
            .foregroundColor(.red)
        case .running where model.streamingText.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.submittedMode == .polish ? "正在润色…" : "正在翻译…")
                    .font(Typography.ui(13))
                    .foregroundColor(.secondary)
            }
            .frame(height: 28)
        default:
            let segments = model.revisionSegments
            let showsMarks = segments != nil && model.showsRevisions
            VStack(alignment: .leading, spacing: 6) {
                GrowingTextView(
                    text: model.stage == .running ? model.streamingText + " ▍" : model.resultText,
                    attributedText: showsMarks ? segments.map(revisionText) : nil,
                    font: Typography.result(size: model.submittedMode == .polish ? 17 : 19),
                    isEditable: model.stage == .preview && !showsMarks,
                    maxHeight: 300,
                    height: $resultHeight,
                    onChange: model.editResult,
                    onCommand: handle
                )
                .frame(height: resultHeight)
                if let segments {
                    revisionBar(changes: TextDiff.changeCount(segments))
                }
            }
        }
    }

    private func revisionBar(changes: Int) -> some View {
        HStack(spacing: 8) {
            Text(changes == 0 ? "没有需要修改的地方" : "\(changes) 处修改")
                .font(Typography.ui(12))
                .foregroundColor(.secondary)
            HintButton(
                key: "⌘D",
                title: model.showsRevisions ? "隐藏修订，直接编辑" : "显示修订",
                action: model.toggleRevisions
            )
            .keyboardShortcut("d", modifiers: .command)
        }
    }

    private func revisionText(_ segments: [TextDiff.Segment]) -> NSAttributedString {
        let font = Typography.result(size: 17)
        let result = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .same(let text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor,
                ]))
            case .removed(let text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemRed,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.systemRed,
                ]))
            case .inserted(let text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: RevisionColors.insertedText,
                    .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.16),
                ]))
            }
        }
        return result
    }

    // MARK: - 语气

    private var toneRow: some View {
        HStack(spacing: 7) {
            ForEach(Array(model.visibleTones.enumerated()), id: \.element) { index, tone in
                Chip(
                    title: tone.chipName,
                    shortcut: index < 5 ? "⌘\(index + 1)" : nil,
                    isSelected: tone == model.tone
                ) {
                    model.setTone(tone)
                }
                .optionalShortcut(index < 5 ? KeyEquivalent(Character("\(index + 1)")) : nil)
            }
            Menu {
                ForEach(model.otherTones, id: \.self) { tone in
                    Button(tone.displayName) { model.setTone(tone) }
                }
            } label: {
                Text("更多…")
                    .font(Typography.ui(12.5))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }

    // MARK: - 微调（⌘L）

    private var refineRow: some View {
        HStack(spacing: 7) {
            Text("微调")
                .font(Typography.ui(12))
                .foregroundColor(.secondary)
            ForEach(["更短", "更正式", "更口语"], id: \.self) { preset in
                Chip(title: preset, shortcut: nil, isSelected: false) {
                    model.refine(instruction: preset)
                }
            }
            TextField("或者写一句要求，回车执行", text: $refineText)
                .textFieldStyle(.plain)
                .font(Typography.ui(12.5))
                .focused($refineFieldFocused)
                .onSubmit { model.refine(instruction: refineText) }
                .onExitCommand { closeRefine() }
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 0.5))
            HintButton(key: "esc", title: "返回", action: closeRefine)
        }
    }

    private func openRefine() {
        guard model.stage == .preview else { return }
        refining.toggle()
        if refining {
            DispatchQueue.main.async { refineFieldFocused = true }
        }
    }

    private func closeRefine() {
        refining = false
        refineText = ""
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            footerHints
            Spacer(minLength: 8)
            PrimaryButton(
                title: primaryTitle,
                isBusy: inToneView ? toneBoard.chosenText == nil : model.stage == .running,
                action: actions.primary
            )
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    @ViewBuilder
    private var footerHints: some View {
        HStack(spacing: 12) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(Typography.ui(12))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            } else if !model.target.accessibilityTrusted {
                Label("未授权辅助功能 · 结果只能复制", systemImage: "lock.shield")
                    .font(Typography.ui(12))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .help("在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 AIInput")
            }
            if inToneView {
                Text("⌘1–4 选中")
                    .font(Typography.ui(12))
                    .foregroundColor(.secondary)
                HintButton(key: "⌘K", title: "用选中的回到单个", action: model.toggleToneView)
                HintButton(key: "esc", title: "关闭", action: actions.close)
            } else {
                stageHints
            }
        }
    }

    @ViewBuilder
    private var stageHints: some View {
        HStack(spacing: 12) {
            switch model.stage {
            case .idle:
                HintButton(key: "esc", title: "关闭", action: actions.close)
            case .running:
                HintButton(key: "esc", title: "取消", action: actions.close)
            case .preview:
                HintButton(key: "⌘L", title: "微调", action: openRefine)
                    .keyboardShortcut("l", modifiers: .command)
                HintButton(key: "⌘R", title: "重来", action: model.submit)
                    .keyboardShortcut("r", modifiers: .command)
                HintButton(key: "⇧⌘C", title: "复制", action: actions.copy)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                HintButton(key: "esc", title: "关闭", action: actions.close)
            case .failed:
                HintButton(key: "⌘R", title: "重试", action: model.submit)
                    .keyboardShortcut("r", modifiers: .command)
                HintButton(key: "esc", title: "关闭", action: actions.close)
            }
        }
    }

    private var primaryTitle: String {
        if inToneView {
            guard let chosen = toneBoard.chosen, toneBoard.chosenText != nil else { return "等待结果" }
            let name = "「\(chosen.chipName)」"
            guard model.target.canPaste else { return "复制\(name)" }
            return model.origin == .selection ? "用\(name)替换" : "粘贴\(name)"
        }
        switch model.stage {
        case .idle:
            return model.resolvedMode == .polish ? "润色" : "翻译"
        case .running:
            return "生成中"
        case .preview:
            guard model.target.canPaste else { return "复制" }
            if model.origin == .selection { return "替换选区" }
            return model.target.appName.map { "粘贴到 \($0)" } ?? "粘贴"
        case .failed:
            return "重试"
        }
    }

    private func handle(_ command: GrowingTextView.Command) -> Bool {
        switch command {
        case .escape:
            actions.close()
            return true
        case .tab:
            model.toggleMode()
            return true
        case .moveUpWhenEmpty:
            return model.restoreLastSource()
        }
    }
}

// MARK: - 组件

private enum RevisionColors {
    /// 深浅色模式下都清楚的绿色：浅色用深绿，深色用浅绿。
    static let insertedText = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.45, blue: 0.16, alpha: 1)
    }
}

struct Keycap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Typography.keycap)
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.22), lineWidth: 0.5)
            )
    }
}

private struct Chip: View {
    let title: String
    let shortcut: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let shortcut {
                    Text(shortcut)
                        .font(Typography.keycap)
                        .opacity(0.7)
                }
            }
            .font(Typography.ui(12.5, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12),
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HintButton: View {
    let key: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Keycap(key)
                Text(title)
                    .font(Typography.ui(12))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PrimaryButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .colorInvert()
                        .brightness(0.2)
                }
                Text(title)
                    .font(Typography.ui(13.5, weight: .semibold))
                Text("⌘⏎")
                    .font(Typography.keycap)
                    .opacity(0.6)
            }
            .foregroundColor(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(isBusy ? 0.55 : 0.92)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    @ViewBuilder
    func optionalShortcut(_ key: KeyEquivalent?) -> some View {
        if let key {
            keyboardShortcut(key, modifiers: .command)
        } else {
            self
        }
    }
}
