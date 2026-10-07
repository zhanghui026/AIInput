import Foundation

/// 一道复习题：先看题面自己回想，再揭晓答案，最后自评「忘了 / 模糊 / 记住」。
/// 题目完全由收进来的条目生成，不需要用户额外录入，也不再请求模型。
struct ReviewQuestion: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// 把当初遇到它的那句话里的词挖掉。
        case cloze
        /// 看中文，回想英文说法。
        case recall
        /// 看句型填空，回想句型骨架。
        case pattern
        /// 看英文，回想中文意思（没有存下中文提示时的兜底）。
        case meaning
    }

    let style: Style
    let prompt: String
    let hint: String?
    let answer: String
    /// 揭晓时补充：原句。
    let detail: String?

    var instruction: String {
        switch style {
        case .cloze: return "这个空该填什么？"
        case .recall: return "用英文怎么说？"
        case .pattern: return "这个句型是什么？"
        case .meaning: return "是什么意思？"
        }
    }
}

enum ReviewQuestionFactory {
    static let blank = "_____"

    /// 同一条每次复习换一种题型，轮流出。
    static func make(for entry: NotebookEntry) -> ReviewQuestion {
        var candidates: [ReviewQuestion] = []
        if let cloze = cloze(for: entry) { candidates.append(cloze) }
        if let pattern = pattern(for: entry) { candidates.append(pattern) }
        candidates.append(recall(for: entry))
        return candidates[entry.reviews.count % candidates.count]
    }

    private static func cloze(for entry: NotebookEntry) -> ReviewQuestion? {
        guard entry.kind != .sentence,
              let context = entry.context, !context.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: "\\b" + NSRegularExpression.escapedPattern(for: entry.surface) + "\\b",
                  options: .caseInsensitive),
              regex.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)) != nil else {
            return nil
        }
        let prompt = regex.stringByReplacingMatches(
            in: context, range: NSRange(context.startIndex..., in: context),
            withTemplate: NSRegularExpression.escapedTemplate(for: blank))
        return ReviewQuestion(style: .cloze, prompt: prompt,
                              hint: entry.gloss.isEmpty ? nil : entry.gloss,
                              answer: entry.surface, detail: context)
    }

    private static func pattern(for entry: NotebookEntry) -> ReviewQuestion? {
        guard let skeleton = entry.pattern, !skeleton.isEmpty,
              let drill = entry.drill, drill.contains("__") else {
            return nil
        }
        return ReviewQuestion(style: .pattern, prompt: drill,
                              hint: entry.gloss.isEmpty ? nil : entry.gloss,
                              answer: skeleton, detail: entry.context)
    }

    private static func recall(for entry: NotebookEntry) -> ReviewQuestion {
        if entry.gloss.isEmpty {
            return ReviewQuestion(style: .meaning, prompt: entry.surface, hint: nil, answer: "", detail: entry.context)
        }
        return ReviewQuestion(style: .recall, prompt: entry.gloss, hint: nil, answer: entry.surface, detail: entry.context)
    }
}

/// 一轮复习：把到期的条目排成队，忘了的在本轮末尾再问一次。
@MainActor
final class ReviewSession: ObservableObject {
    nonisolated static let defaultLimit = 20

    @Published private(set) var current: NotebookEntry?
    @Published private(set) var question: ReviewQuestion?
    @Published private(set) var revealed = false
    @Published private(set) var graded = 0
    @Published private(set) var total = 0
    @Published private(set) var started = false
    @Published private(set) var counts: [ReviewGrade: Int] = [:]

    private let notebook: NotebookStore
    private var queue: [UUID] = []
    private var requeued: Set<UUID> = []
    private var asked: Set<UUID> = []

    init(notebook: NotebookStore) {
        self.notebook = notebook
    }

    var isFinished: Bool { current == nil }

    func start(now: Date = Date(), limit: Int = ReviewSession.defaultLimit) {
        queue = notebook.dueEntries(now: now).prefix(limit).map(\.id)
        requeued = []
        asked = []
        counts = [:]
        graded = 0
        total = queue.count
        started = true
        advance()
    }

    func reveal() {
        guard current != nil else { return }
        revealed = true
    }

    func grade(_ grade: ReviewGrade, now: Date = Date()) {
        guard let entry = current else { return }
        // 本轮末尾的再问一次只计入本轮数字，不再改排期。
        if asked.insert(entry.id).inserted { notebook.recordReview(id: entry.id, grade: grade, now: now) }
        counts[grade, default: 0] += 1
        graded += 1
        if grade == .forgot, requeued.insert(entry.id).inserted {
            queue.append(entry.id)
            total += 1
        }
        advance()
    }

    private func advance() {
        revealed = false
        while let id = queue.first {
            queue.removeFirst()
            if let entry = notebook.entries.first(where: { $0.id == id }) {
                current = entry
                question = ReviewQuestionFactory.make(for: entry)
                return
            }
        }
        current = nil
        question = nil
    }
}
