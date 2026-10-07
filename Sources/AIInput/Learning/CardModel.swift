import Foundation

/// 学习卡片（⌘I）的状态：当前对象、已到达的区块、嵌套查看的路径、是否已收进本子。
/// 不依赖 AppKit，可以单测。由 `PanelModel` 持有，像 `ToneBoard` 一样自带一个
/// `generation`：每次换对象都换新值，上一张卡片迟到的输出据此丢弃。
@MainActor
final class CardModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var target: CardTarget?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var blocks: [CardBlock] = []
    /// 之前看过的卡片（面包屑），最后一个是上一张。
    @Published private(set) var trail: [CardTarget] = []
    /// 这个词/句子累计被查的次数，含这一次；记录关闭时为 0。
    @Published private(set) var lookupCount = 0
    @Published private(set) var earlierContexts: [String] = []
    @Published private(set) var dictionaryText: String?
    @Published private(set) var isSaved = false
    /// 来源 App，随收藏一起存下来。
    var appName: String?

    private let generator: CardGenerating
    private let preferences: PanelPreferences
    private let notebook: NotebookStore
    private let lookups: LookupLog
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var cache: [CacheKey: [CardBlock]] = [:]
    /// 用户手动改过类型（⌘1–3）的文字，本次运行内记住。
    private var kindOverrides: [String: CardKind] = [:]

    private struct CacheKey: Hashable {
        let kind: CardKind
        let text: String
        let context: String
    }

    init(generator: CardGenerating,
         preferences: PanelPreferences,
         notebook: NotebookStore,
         lookups: LookupLog) {
        self.generator = generator
        self.preferences = preferences
        self.notebook = notebook
        self.lookups = lookups
    }

    var isLoading: Bool { stage == .loading }

    // MARK: - 打开与导航

    /// 从面板的原文打开：重新开始，清空路径。
    func open(text: String, context: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = SelectionClassifier.normalized(text)
        guard let kind = kindOverrides[normalized] ?? SelectionClassifier.kind(for: text) else { return }
        trail = []
        show(CardTarget(text: text, kind: kind, context: context), recording: true)
    }

    /// 回到视图时继续：被取消过的请求重新开始，已有结果的保持不变。
    func resume() {
        guard let target, stage == .idle else { return }
        show(target, recording: false)
    }

    /// 点击词族、同类说法等 chip：在当前卡片之上再打开一张。
    func push(_ item: String) {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = target, !item.isEmpty else { return }
        let normalized = SelectionClassifier.normalized(item)
        guard let kind = kindOverrides[normalized] ?? SelectionClassifier.kind(for: item) else { return }
        let sentence = current.context ?? (current.kind == .word ? nil : current.text)
        let context = sentence.flatMap { $0.range(of: item, options: [.caseInsensitive, .diacriticInsensitive]) != nil ? $0 : nil }
        trail.append(current)
        show(CardTarget(text: item, kind: kind, context: context), recording: true)
    }

    func pop() {
        guard let previous = trail.popLast() else { return }
        show(previous, recording: false)
    }

    /// 自动判断错了时手动改类型，按新类型重新生成。
    func setKind(_ kind: CardKind) {
        guard let current = target, current.kind != kind else { return }
        kindOverrides[SelectionClassifier.normalized(current.text)] = kind
        var next = current
        next.kind = kind
        show(next, recording: true)
    }

    func retry() {
        guard let target else { return }
        cache[cacheKey(for: target)] = nil
        show(target, recording: false)
    }

    // MARK: - 收藏与朗读

    func toggleSaved() {
        guard let target, stage == .ready else { return }
        let key = LookupKey.make(kind: target.kind, text: target.text)
        if isSaved {
            notebook.remove(key: key)
        } else {
            notebook.save(target: target, blocks: blocks, appName: appName)
        }
        isSaved = notebook.contains(key: key)
    }

    func speak() {
        guard let target else { return }
        Speaker.shared.speak(target.text)
    }

    // MARK: - 取消与清空

    /// 离开卡片视图：停掉还在生成的请求，已完成的保留。
    func cancelRunning() {
        guard stage == .loading else { return }
        cancelTask()
        blocks = []
        stage = .idle
    }

    func reset() {
        cancelTask()
        target = nil
        trail = []
        blocks = []
        stage = .idle
        lookupCount = 0
        earlierContexts = []
        dictionaryText = nil
        isSaved = false
    }

    // MARK: - 生成

    private func cacheKey(for target: CardTarget) -> CacheKey {
        CacheKey(kind: target.kind,
                 text: SelectionClassifier.normalized(target.text),
                 context: target.context ?? "")
    }

    private func show(_ next: CardTarget, recording: Bool) {
        cancelTask()
        generation = UUID()
        target = next
        blocks = []
        let key = LookupKey.make(kind: next.kind, text: next.text)
        dictionaryText = next.kind == .word ? SystemDictionary.definition(for: next.text) : nil
        if recording { recordLookup(next, key: key) }

        if let saved = notebook.entry(forKey: key), saved.kind == next.kind, !saved.blocks.isEmpty {
            isSaved = true
            blocks = saved.blocks
            stage = .ready
            return
        }
        isSaved = false
        if let cached = cache[cacheKey(for: next)] {
            blocks = cached
            stage = .ready
            return
        }
        generate(next)
    }

    private func recordLookup(_ target: CardTarget, key: String) {
        guard preferences.lookupLogEnabled else {
            lookupCount = 0
            earlierContexts = []
            return
        }
        earlierContexts = lookups.earlierContexts(forKey: key, excluding: target.context)
        lookupCount = lookups.record(target: target, appName: appName)
    }

    private func generate(_ target: CardTarget) {
        stage = .loading
        let id = generation
        let request = CardRequest(target: target, customInstructions: preferences.customInstructions)
        let parser = CardStreamParser()
        let generator = generator
        task = Task { [weak self] in
            do {
                let raw = try await generator.generate(request) { [weak self] partial in
                    guard let self, self.generation == id else { return }
                    self.blocks += parser.update(with: partial)
                }
                guard let self, self.generation == id else { return }
                self.blocks += parser.update(with: raw)
                self.task = nil
                guard !self.blocks.isEmpty else {
                    self.stage = .failed("没能生成卡片，请重试。")
                    return
                }
                self.stage = .ready
                if self.cache.count > 60 { self.cache.removeAll() }
                self.cache[self.cacheKey(for: target)] = self.blocks
            } catch {
                guard let self, self.generation == id, !(error is CancellationError) else { return }
                self.task = nil
                Log.flow.error("card: 生成失败：\(error.localizedDescription, privacy: .public)")
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        generation = UUID()
    }
}
