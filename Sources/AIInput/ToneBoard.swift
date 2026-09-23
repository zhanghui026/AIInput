import Foundation

/// 多语气视图的分组：常用 + 按场景分的三组，每组最多四个，正好一屏 2×2。
enum ToneGroup: String, CaseIterable, Sendable {
    case favorites
    case work
    case everyday
    case written

    var displayName: String {
        switch self {
        case .favorites: return "常用"
        case .work: return "职场"
        case .everyday: return "日常"
        case .written: return "书面"
        }
    }

    func tones(favorites: [WritingTone]) -> [WritingTone] {
        switch self {
        case .favorites: return Array(favorites.prefix(4))
        case .work: return [.professional, .formal, .direct, .confident]
        case .everyday: return [.natural, .friendly, .conversational, .concise]
        case .written: return [.faithful, .academic, .objective]
        }
    }
}

/// 同一段原文按多个语气并行生成的结果。只生成当前分组里还没有结果的语气，
/// 切换分组来回看不会重复请求；原文、模式或方向变化时整体作废。
@MainActor
final class ToneBoard: ObservableObject {
    enum Card: Equatable {
        case running(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var group: ToneGroup = .favorites
    @Published private(set) var cards: [WritingTone: Card] = [:]
    @Published private(set) var chosen: WritingTone?

    private let transformer: TextTransforming
    private let preferences: PanelPreferences
    private var tasks: [WritingTone: Task<Void, Never>] = [:]
    private var context: Context?
    /// 每次作废都换新值，迟到的结果据此丢弃。
    private var generation = UUID()

    private struct Context: Equatable {
        let text: String
        let mode: TransformMode
    }

    init(transformer: TextTransforming, preferences: PanelPreferences) {
        self.transformer = transformer
        self.preferences = preferences
    }

    var tones: [WritingTone] {
        group.tones(favorites: preferences.favoriteTones)
    }

    var chosenText: String? {
        guard let chosen, case .done(let text)? = cards[chosen] else { return nil }
        return text
    }

    /// 打开视图：原文或模式变了就清空重来，然后补齐当前分组。
    func open(text: String, mode: TransformMode, currentTone: WritingTone) {
        let next = Context(text: text, mode: mode)
        if next != context {
            reset()
            context = next
        }
        if chosen == nil {
            chosen = tones.contains(currentTone) ? currentTone : tones.first
        }
        requestMissing()
    }

    func selectGroup(_ newGroup: ToneGroup) {
        group = newGroup
        if let chosen, !tones.contains(chosen) {
            self.chosen = tones.first
        }
        requestMissing()
    }

    func moveGroup(offset: Int) {
        let all = ToneGroup.allCases
        guard let index = all.firstIndex(of: group) else { return }
        selectGroup(all[(index + offset + all.count) % all.count])
    }

    func choose(_ tone: WritingTone) {
        chosen = tone
    }

    func choose(index: Int) {
        guard tones.indices.contains(index) else { return }
        chosen = tones[index]
    }

    func retry(_ tone: WritingTone) {
        tasks[tone]?.cancel()
        tasks[tone] = nil
        cards[tone] = nil
        request(tone)
    }

    /// 离开视图：停止还在生成的卡片（下次打开再补），已完成的保留。
    func cancelRunning() {
        for (tone, card) in cards {
            if case .running = card {
                tasks[tone]?.cancel()
                cards[tone] = nil
            }
        }
        tasks = tasks.filter { cards[$0.key] != nil }
    }

    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        cards = [:]
        chosen = nil
        context = nil
        generation = UUID()
    }

    private func requestMissing() {
        for tone in tones where cards[tone] == nil {
            request(tone)
        }
    }

    private func request(_ tone: WritingTone) {
        guard let context else { return }
        let request = TransformationRequest(
            mode: context.mode,
            tone: tone,
            text: context.text,
            customInstructions: preferences.customInstructions
        )
        let generation = generation
        cards[tone] = .running("")
        let transformer = transformer
        tasks[tone] = Task { [weak self] in
            do {
                let result = try await transformer.perform(request) { [weak self] partial in
                    guard let self, self.generation == generation else { return }
                    self.cards[tone] = .running(partial)
                }
                guard let self, self.generation == generation else { return }
                self.cards[tone] = .done(result)
                self.tasks[tone] = nil
            } catch {
                guard let self, self.generation == generation, !(error is CancellationError) else { return }
                self.cards[tone] = .failed(error.localizedDescription)
                self.tasks[tone] = nil
            }
        }
    }
}
