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
    var historyEnabled: Bool { get }
    var lookupLogEnabled: Bool { get }
}

extension PanelPreferences {
    var lookupLogEnabled: Bool { true }
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
    var historyEnabled: Bool { Config.historyEnabled }
    var lookupLogEnabled: Bool { Config.lookupLogEnabled }
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
        case history
        case card
    }

    enum PrimaryAction: Equatable {
        case none
        case submit
        case paste(String)
        case copy(String)
        /// 卡片视图里 ⌘⏎：回到翻译结果。
        case closeCard
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
    @Published private(set) var historyIndex = 0
    let history: HistoryStore
    /// 润色结果是否标出修订痕迹（⌘D 切换）。
    @Published private(set) var showsRevisions = true
    let toneBoard: ToneBoard
    let card: CardModel
    /// 原文里选中文字所在的整句（只有从选区读到时才有）。
    private(set) var sourceContext: String?
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

    init(transformer: TextTransforming,
         preferences: PanelPreferences,
         history: HistoryStore? = nil,
         cardGenerator: CardGenerating? = nil,
         notebook: NotebookStore? = nil,
         lookups: LookupLog? = nil) {
        self.transformer = transformer
        self.preferences = preferences
        self.history = history ?? HistoryStore(fileURL: nil)
        toneBoard = ToneBoard(transformer: transformer, preferences: preferences)
        card = CardModel(
            generator: cardGenerator ?? (transformer as? CardGenerating) ?? UnavailableCardGenerator(),
            preferences: preferences,
            notebook: notebook ?? NotebookStore(fileURL: nil),
            lookups: lookups ?? LookupLog(fileURL: nil)
        )
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
    func load(text: String, origin: Origin, context: String? = nil) {
        cancelRequest()
        toneBoard.reset()
        card.reset()
        sourceContext = text.isEmpty ? nil : context
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
        sourceContext = nil
        toneBoard.reset()
        card.reset()
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
        if mode != .translate, viewMode == .card {
            card.cancelRunning()
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
        case .single, .history, .card:
            guard canShowToneView else { return }
            if viewMode == .card { card.cancelRunning() }
            viewMode = .tones
            openToneBoard()
        case .tones:
            adoptChosenTone()
            toneBoard.cancelRunning()
            viewMode = .single
        }
    }

    // MARK: - 历史（⌘Y）

    func toggleHistory() {
        if viewMode == .history {
            viewMode = .single
            return
        }
        if viewMode == .tones {
            toneBoard.cancelRunning()
        }
        if viewMode == .card {
            card.cancelRunning()
        }
        historyIndex = 0
        viewMode = .history
    }

    func moveHistorySelection(offset: Int) {
        guard !history.entries.isEmpty else { return }
        historyIndex = min(max(historyIndex + offset, 0), history.entries.count - 1)
    }

    func selectHistory(index: Int) {
        guard history.entries.indices.contains(index) else { return }
        historyIndex = index
    }

    var selectedHistoryEntry: HistoryEntry? {
        history.entries.indices.contains(historyIndex) ? history.entries[historyIndex] : nil
    }

    /// 把选中的历史载入单个视图：原文 + 结果，可以继续换语气、微调或直接粘贴。
    func loadHistorySelection() {
        guard let entry = selectedHistoryEntry else { return }
        cancelRequest()
        toneBoard.reset()
        card.reset()
        sourceContext = nil
        sourceText = entry.source
        versions = [Version(text: entry.result, mode: entry.mode, tone: entry.tone)]
        versionIndex = 0
        submittedMode = entry.mode
        stage = .preview
        viewMode = .single
    }

    /// 结果被粘贴、替换或复制时调用，记入历史。
    func noteUsed(_ text: String) {
        guard preferences.historyEnabled else { return }
        let mode: TransformMode
        let usedTone: WritingTone
        switch viewMode {
        case .history:
            guard let entry = selectedHistoryEntry else { return }
            history.record(source: entry.source, result: text, mode: entry.mode,
                           tone: entry.tone, appName: target.appName)
            return
        case .card:
            return
        case .tones:
            mode = resolvedMode
            usedTone = toneBoard.chosen ?? tone
        case .single:
            mode = currentVersion?.mode ?? submittedMode ?? resolvedMode
            usedTone = currentVersion?.tone ?? tone
        }
        history.record(source: sourceText, result: text, mode: mode, tone: usedTone, appName: target.appName)
    }

    // MARK: - 学习卡片（⌘I）

    /// 原文是英文单词、词组或句子时才有卡片；类型自动判断。
    var cardKind: CardKind? {
        SelectionClassifier.kind(for: sourceText)
    }

    var canShowCard: Bool {
        hasSource && cardKind != nil
    }

    func toggleCard() {
        if viewMode == .card {
            card.cancelRunning()
            viewMode = .single
            return
        }
        guard canShowCard else { return }
        if viewMode == .tones {
            toneBoard.cancelRunning()
        }
        viewMode = .card
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        card.appName = target.appName
        if card.trail.isEmpty, card.target?.text == text {
            card.resume()
        } else {
            card.open(text: text, context: sourceContext)
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
        lastSubmittedText = text
        run(TransformationRequest(
            mode: resolvedMode,
            tone: tone,
            text: text,
            customInstructions: preferences.customInstructions
        ))
    }

    /// ⌘L：按一句话要求改写当前结果，得到新版本（⌘[ 可回到改写前）。
    func refine(instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stage == .preview, !instruction.isEmpty, let current = currentVersion else { return }
        run(TransformationRequest(
            mode: current.mode,
            tone: tone,
            text: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            customInstructions: preferences.customInstructions,
            refinement: .init(current: current.text, instruction: instruction)
        ))
    }

    private func run(_ request: TransformationRequest) {
        cancelRequest()
        let mode = request.mode
        submittedMode = mode
        notice = nil
        let id = UUID()
        requestID = id
        streamingText = ""
        stage = .running
        Log.flow.notice("submit: 开始 \(mode.rawValue, privacy: .public)\(request.refinement == nil ? "" : "（微调）", privacy: .public)，\(request.text.count) 字")

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
        if viewMode == .card {
            return .closeCard
        }
        if viewMode == .history {
            guard let text = selectedHistoryEntry?.result else { return .none }
            return target.canPaste ? .paste(text) : .copy(text)
        }
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


/// 没有接入卡片服务时（例如只测面板逻辑）使用，调用就报未配置。
struct UnavailableCardGenerator: CardGenerating {
    func generate(_ request: CardRequest,
                  onPartial: TranslationService.PartialHandler?) async throws -> String {
        throw TranslationService.TranslationError.notConfigured
    }
}
