import Foundation

/// 执行一次文本转换（生产环境是 `TranslationService`，测试里可替换）。
protocol TextTransforming: Sendable {
    func perform(_ request: TransformationRequest,
                 onPartial: TranslationService.PartialHandler?) async throws -> String
}

extension TranslationService: TextTransforming {}

/// 面板选项的持久化（生产环境写 UserDefaults，测试用内存实现）。
@MainActor
protocol PanelPreferences: AnyObject {
    var panelMode: PanelMode { get set }
    var direction: TranslationDirection { get set }
    var tone: WritingTone { get set }
    var favoriteTones: [WritingTone] { get }
    var customInstructions: String { get }
}

@MainActor
final class ConfigPreferences: PanelPreferences {
    var panelMode: PanelMode {
        get { Config.panelMode }
        set { Config.panelMode = newValue }
    }
    var direction: TranslationDirection {
        get { Config.direction }
        set { Config.direction = newValue }
    }
    var tone: WritingTone {
        get { Config.tone }
        set { Config.tone = newValue }
    }
    var favoriteTones: [WritingTone] { Config.favoriteTones }
    var customInstructions: String { Config.customInstructions }
}

/// 面板的全部状态与操作，不依赖 AppKit，便于单测。
/// 外壳（`InputPanel`）负责读取原文、呈现窗口、粘贴/复制。
@MainActor
final class PanelModel: ObservableObject {
    enum Stage: Equatable {
        case idle              // 编辑原文，还没有结果
        case running           // 请求中，结果流式出现
        case preview           // 有结果，待粘贴/复制
        case failed(String)    // 请求失败，结果区显示错误
    }

    /// 原文从哪里来：决定提示文案，以及 ⌘⏎ 是替换选区还是插入光标处。
    enum Origin: Equatable {
        case typed
        case selection
        case clipboard
    }

    struct Version: Equatable {
        var text: String
        let mode: TransformMode
        let tone: WritingTone
    }

    /// 由外壳提供的目标信息，只影响显示和主按钮行为。
    struct Target: Equatable {
        var appName: String?
        var canPaste = false
        var accessibilityTrusted = true
    }

    /// 单个结果，或同时看多个语气（仅翻译）。
    enum ViewMode: Equatable {
        case single
        case tones
    }

    enum PrimaryAction: Equatable {
        case none
        case submit
        case paste(String)
        case copy(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var sourceText = ""
    @Published private(set) var origin: Origin = .typed
    @Published private(set) var panelMode: PanelMode
    @Published private(set) var direction: TranslationDirection
    @Published private(set) var tone: WritingTone
    @Published private(set) var versions: [Version] = []
    @Published private(set) var versionIndex = 0
    @Published private(set) var streamingText = ""
    @Published private(set) var submittedMode: TransformMode?
    @Published private(set) var viewMode: ViewMode = .single
    /// 润色结果是否标出修订痕迹（⌘D 切换）。
    @Published private(set) var showsRevisions = true
    let toneBoard: ToneBoard
    @Published var target = Target()
    /// 底栏的临时提示（例如“未能自动粘贴”），开始新一轮或新请求时清除。
    @Published var notice: String?
    private(set) var lastSubmittedText = ""

    /// 结果就绪时通知外壳（用于“直接粘贴”设置）。
    var onResultReady: ((String) -> Void)?
    /// 输入法正在组词时不提交（外壳接到原文编辑器上）。
    var isComposing: () -> Bool = { false }

    private let transformer: TextTransforming
    private let preferences: PanelPreferences
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    init(transformer: TextTransforming, preferences: PanelPreferences) {
        self.transformer = transformer
        self.preferences = preferences
        toneBoard = ToneBoard(transformer: transformer, preferences: preferences)
        panelMode = preferences.panelMode
        direction = preferences.direction
        tone = preferences.tone
    }

    // MARK: - 派生状态

    /// 按当前选项和原文，下一次提交会执行的任务。
    var resolvedMode: TransformMode {
        ModeResolver.resolve(panelMode: panelMode, direction: direction, text: sourceText)
    }

    /// 结果区应显示的文字：请求中是流式文字，否则是当前版本。
    var resultText: String {
        if stage == .running { return streamingText }
        return currentVersion?.text ?? ""
    }

    var currentVersion: Version? {
        versions.indices.contains(versionIndex) ? versions[versionIndex] : nil
    }

    var hasSource: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 常用语气；当前语气不在其中时临时附在末尾，保证它可见。
    var visibleTones: [WritingTone] {
        let favorites = preferences.favoriteTones
        return favorites.contains(tone) ? favorites : favorites + [tone]
    }

    var otherTones: [WritingTone] {
        WritingTone.allCases.filter { !preferences.favoriteTones.contains($0) }
    }

    // MARK: - 原文

    /// 开始新一轮：载入带进来的原文（或清空），丢弃旧结果。
    func load(text: String, origin: Origin) {
        cancelRequest()
        toneBoard.reset()
        viewMode = .single
        notice = nil
        sourceText = text
        self.origin = text.isEmpty ? .typed : origin
        versions = []
        versionIndex = 0
        submittedMode = nil
        stage = .idle
    }

    /// 用户修改原文：旧结果和进行中的请求都作废。
    func editSource(_ text: String) {
        guard text != sourceText else { return }
        sourceText = text
        toneBoard.reset()
        viewMode = .single
        if text.isEmpty {
            origin = .typed
        }
        if stage != .idle {
            cancelRequest()
            versions = []
            versionIndex = 0
            stage = .idle
        }
    }

    /// 原文为空时 ↑：恢复上次提交的原文。
    @discardableResult
    func restoreLastSource() -> Bool {
        guard stage == .idle, sourceText.isEmpty, !lastSubmittedText.isEmpty else { return false }
        sourceText = lastSubmittedText
        return true
    }

    /// 用户直接修改结果：改的是当前版本，粘贴时用修改后的文字。
    func editResult(_ text: String) {
        guard stage == .preview, versions.indices.contains(versionIndex) else { return }
        versions[versionIndex].text = text
    }

    // MARK: - 选项（改动即持久化；已有结果时立即按新选项重写）

    func setTone(_ newTone: WritingTone) {
        guard newTone != tone else { return }
        tone = newTone
        preferences.tone = newTone
        rerunIfNeeded()
    }

    func setPanelMode(_ mode: PanelMode) {
        guard mode != panelMode else { return }
        panelMode = mode
        preferences.panelMode = mode
        if mode != .translate, viewMode == .tones {
            // 多语气视图只用于翻译。
            toneBoard.reset()
            viewMode = .single
        }
        rerunIfNeeded()
    }

    func toggleMode() {
        setPanelMode(panelMode == .translate ? .polish : .translate)
    }

    func setDirection(_ newDirection: TranslationDirection) {
        guard newDirection != direction else { return }
        direction = newDirection
        preferences.direction = newDirection
        rerunIfNeeded()
    }

    private func rerunIfNeeded() {
        if viewMode == .tones {
            openToneBoard()
        } else if stage != .idle {
            submit()
        }
    }

    // MARK: - 多语气视图（⌘K）

    var canShowToneView: Bool {
        panelMode == .translate && hasSource
    }

    /// 打开或关闭多语气视图；关闭时把选中的那张卡片作为新版本带回单个视图。
    func toggleToneView() {
        switch viewMode {
        case .single:
            guard canShowToneView else { return }
            viewMode = .tones
            openToneBoard()
        case .tones:
            adoptChosenTone()
            toneBoard.cancelRunning()
            viewMode = .single
        }
    }

    private func openToneBoard() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        toneBoard.open(text: text, mode: resolvedMode, currentTone: tone)
    }

    private func adoptChosenTone() {
        guard let chosen = toneBoard.chosen, let text = toneBoard.chosenText else { return }
        cancelRequest()
        tone = chosen
        preferences.tone = chosen
        let mode = resolvedMode
        submittedMode = mode
        if currentVersion?.text != text {
            versions.append(Version(text: text, mode: mode, tone: chosen))
            versionIndex = versions.count - 1
        }
        stage = .preview
    }

    // MARK: - 修订痕迹（润色）

    /// 润色结果相对原文的改动；不是润色结果或正在生成时为 nil。
    var revisionSegments: [TextDiff.Segment]? {
        guard stage == .preview, currentVersion?.mode == .polish, let current = currentVersion else {
            return nil
        }
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextDiff.segments(from: source, to: current.text)
    }

    func toggleRevisions() {
        showsRevisions.toggle()
    }

    // MARK: - 版本

    func showVersion(offset: Int) {
        guard stage != .running else { return }
        let index = versionIndex + offset
        guard versions.indices.contains(index) else { return }
        versionIndex = index
        stage = .preview
    }

    // MARK: - 请求

    func submit() {
        guard !isComposing() else { return }
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelRequest()
        lastSubmittedText = text

        let mode = resolvedMode
        submittedMode = mode
        let request = TransformationRequest(
            mode: mode,
            tone: tone,
            text: text,
            customInstructions: preferences.customInstructions
        )
        notice = nil
        let id = UUID()
        requestID = id
        streamingText = ""
        stage = .running
        Log.flow.notice("submit: 开始 \(mode.rawValue, privacy: .public)，\(text.count) 字")

        let transformer = transformer
        task = Task { [weak self] in
            do {
                let result = try await transformer.perform(request) { [weak self] partial in
                    guard let self, self.requestID == id else { return }
                    self.streamingText = partial
                }
                guard let self, self.requestID == id else { return }
                self.finish(with: result, mode: mode, tone: request.tone)
            } catch {
                guard let self, self.requestID == id, !(error is CancellationError) else { return }
                self.requestID = nil
                self.task = nil
                Log.flow.error("submit: 处理失败：\(error.localizedDescription, privacy: .public)")
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(with result: String, mode: TransformMode, tone: WritingTone) {
        requestID = nil
        task = nil
        Log.flow.notice("submit: 处理成功（\(result.count) 字符）")
        versions.append(Version(text: result, mode: mode, tone: tone))
        versionIndex = versions.count - 1
        streamingText = ""
        stage = .preview
        onResultReady?(result)
    }

    /// 取消进行中的请求；有旧版本时回到它，否则回到编辑原文。
    func cancel() {
        toneBoard.cancelRunning()
        guard stage == .running else { return }
        cancelRequest()
        stage = versions.isEmpty ? .idle : .preview
    }

    private func cancelRequest() {
        guard requestID != nil || task != nil else { return }
        requestID = nil
        task?.cancel()
        task = nil
        streamingText = ""
        Log.flow.notice("submit: 取消进行中的请求")
    }

    // MARK: - 主按钮 ⌘⏎

    func primaryAction() -> PrimaryAction {
        if viewMode == .tones {
            guard let text = toneBoard.chosenText else { return .none }
            return target.canPaste ? .paste(text) : .copy(text)
        }
        switch stage {
        case .idle, .failed:
            return hasSource ? .submit : .none
        case .running:
            return .none
        case .preview:
            let text = resultText
            guard !text.isEmpty else { return .none }
            return target.canPaste ? .paste(text) : .copy(text)
        }
    }
}
