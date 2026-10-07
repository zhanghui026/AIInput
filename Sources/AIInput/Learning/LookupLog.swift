import Foundation

struct LookupRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var key: String
    var text: String
    var kind: CardKind
    var date: Date
    var context: String?
    var appName: String?
}

/// 每次打开卡片自动记一笔，用来显示「第 N 次查」、翻出以前遇到它的句子，以及做统计。
/// 只存在本机；设置里可以关闭或清空。
@MainActor
final class LookupLog: ObservableObject {
    static let limit = 5_000
    /// 同一个键在这段时间内再次打开（比如来回切换 ⌘I）不重复计数。
    static let dedupeInterval: TimeInterval = 60

    @Published private(set) var records: [LookupRecord] = []
    private let storage: JSONFileStorage<LookupRecord>

    init(fileURL: URL? = JSONFileStorage<LookupRecord>.defaultURL("lookups.json")) {
        storage = JSONFileStorage(url: fileURL)
        records = Array(storage.load().sorted { $0.date > $1.date }.prefix(Self.limit))
    }

    func count(forKey key: String) -> Int {
        records.reduce(0) { $0 + ($1.key == key ? 1 : 0) }
    }

    /// 以前遇到它时所在的句子，最近的在前，去重。
    func earlierContexts(forKey key: String, excluding current: String?, limit: Int = 3) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for record in records where record.key == key {
            guard let context = record.context, !context.isEmpty, context != current,
                  seen.insert(context).inserted else { continue }
            result.append(context)
            if result.count == limit { break }
        }
        return result
    }

    /// 记一次查询，返回这个键累计被查的次数（含这一次）。
    @discardableResult
    func record(target: CardTarget, appName: String?, now: Date = Date()) -> Int {
        let key = LookupKey.make(kind: target.kind, text: target.text)
        if let last = records.first(where: { $0.key == key }),
           now.timeIntervalSince(last.date) < Self.dedupeInterval {
            return count(forKey: key)
        }
        records.insert(
            LookupRecord(id: UUID(), key: key,
                         text: target.text.trimmingCharacters(in: .whitespacesAndNewlines),
                         kind: target.kind, date: now, context: target.context, appName: appName),
            at: 0
        )
        if records.count > Self.limit {
            records.removeLast(records.count - Self.limit)
        }
        storage.save(records)
        return count(forKey: key)
    }

    func clear() {
        records = []
        storage.remove()
    }

    func flush() {
        storage.flush()
    }
}
