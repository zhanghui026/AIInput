import Foundation

/// 生词本 / 句型本里的一条。复习需要的东西（原形、原句、中文提示、句型）单独存，
/// 不依赖 `blocks` 的具体格式；`blocks` 只用来再次显示整张卡片。
struct NotebookEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: CardKind
    /// 查词记录用的键，单词是原形。
    var key: String
    /// 当时选中的原样文字。
    var surface: String
    /// 它所在的整句。
    var context: String?
    /// 一句中文提示，复习时用。
    var gloss: String
    var pattern: String?
    var drill: String?
    var blocks: [CardBlock]
    var appName: String?
    var createdAt: Date
    var review: ReviewState
    var reviews: [ReviewEvent]

    static let reviewHistoryLimit = 60

    init(id: UUID = UUID(), kind: CardKind, key: String, surface: String, context: String?,
         gloss: String, pattern: String?, drill: String?, blocks: [CardBlock], appName: String?,
         createdAt: Date, review: ReviewState, reviews: [ReviewEvent] = []) {
        self.id = id
        self.kind = kind
        self.key = key
        self.surface = surface
        self.context = context
        self.gloss = gloss
        self.pattern = pattern
        self.drill = drill
        self.blocks = blocks
        self.appName = appName
        self.createdAt = createdAt
        self.review = review
        self.reviews = reviews
    }

    static func make(target: CardTarget, blocks: [CardBlock], appName: String?, now: Date) -> NotebookEntry {
        let pattern = blocks.firstPattern
        return NotebookEntry(
            kind: target.kind,
            key: LookupKey.make(kind: target.kind, text: target.text),
            surface: target.text.trimmingCharacters(in: .whitespacesAndNewlines),
            context: target.context,
            gloss: blocks.firstGloss ?? "",
            pattern: pattern?.skeleton,
            drill: pattern?.drill,
            blocks: blocks,
            appName: appName,
            createdAt: now,
            review: .initial(now: now)
        )
    }

    // 读取时对缺失字段宽容，以后加字段不会让旧文件整条丢掉。
    private enum CodingKeys: String, CodingKey {
        case id, kind, key, surface, context, gloss, pattern, drill, blocks, appName, createdAt, review, reviews
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.init(
            id: (try? c.decode(UUID.self, forKey: .id)) ?? UUID(),
            kind: try c.decode(CardKind.self, forKey: .kind),
            key: try c.decode(String.self, forKey: .key),
            surface: try c.decode(String.self, forKey: .surface),
            context: try c.decodeIfPresent(String.self, forKey: .context),
            gloss: (try? c.decode(String.self, forKey: .gloss)) ?? "",
            pattern: try c.decodeIfPresent(String.self, forKey: .pattern),
            drill: try c.decodeIfPresent(String.self, forKey: .drill),
            blocks: ((try? c.decode([Lossy<CardBlock>].self, forKey: .blocks)) ?? []).compactMap(\.value),
            appName: try c.decodeIfPresent(String.self, forKey: .appName),
            createdAt: createdAt,
            review: (try? c.decode(ReviewState.self, forKey: .review)) ?? .initial(now: createdAt),
            reviews: (try? c.decode([ReviewEvent].self, forKey: .reviews)) ?? []
        )
    }
}

@MainActor
final class NotebookStore: ObservableObject {
    @Published private(set) var entries: [NotebookEntry] = []
    private let storage: JSONFileStorage<NotebookEntry>

    init(fileURL: URL? = JSONFileStorage<NotebookEntry>.defaultURL("notebook.json")) {
        storage = JSONFileStorage(url: fileURL)
        entries = storage.load().sorted { $0.createdAt > $1.createdAt }
    }

    func entry(forKey key: String) -> NotebookEntry? {
        entries.first { $0.key == key }
    }

    func contains(key: String) -> Bool {
        entry(forKey: key) != nil
    }

    /// 收进本子；同一个键、同一类型已经有了就原样返回，不重复。
    /// 词组和整句共用一个键，类型不同时换成新的那条。
    @discardableResult
    func save(target: CardTarget, blocks: [CardBlock], appName: String?, now: Date = Date()) -> NotebookEntry {
        let entry = NotebookEntry.make(target: target, blocks: blocks, appName: appName, now: now)
        if let existing = self.entry(forKey: entry.key) {
            if existing.kind == entry.kind { return existing }
            entries.removeAll { $0.key == entry.key }
        }
        entries.insert(entry, at: 0)
        persist()
        return entry
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func remove(key: String) {
        entries.removeAll { $0.key == key }
        persist()
    }

    func recordReview(id: UUID, grade: ReviewGrade, now: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].review = ReviewScheduler.next(entries[index].review, grade: grade, now: now)
        entries[index].reviews.append(ReviewEvent(date: now, grade: grade))
        if entries[index].reviews.count > NotebookEntry.reviewHistoryLimit {
            entries[index].reviews.removeFirst(entries[index].reviews.count - NotebookEntry.reviewHistoryLimit)
        }
        persist()
    }

    func dueEntries(now: Date = Date()) -> [NotebookEntry] {
        entries.filter { $0.review.due <= now }.sorted { $0.review.due < $1.review.due }
    }

    func dueCount(now: Date = Date()) -> Int {
        entries.reduce(0) { $0 + ($1.review.due <= now ? 1 : 0) }
    }

    func clear() {
        entries = []
        storage.remove()
    }

    func flush() {
        storage.flush()
    }

    private func persist() {
        storage.save(entries)
    }
}

/// 生词本和查词记录在整个 App 里只有一份，面板和学习窗口共用。
@MainActor
final class LearningStores {
    static let shared = LearningStores()

    let notebook = NotebookStore()
    let lookups = LookupLog()
}
