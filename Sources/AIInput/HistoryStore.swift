import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let source: String
    let result: String
    let mode: TransformMode
    let tone: WritingTone
    let appName: String?
}

/// 最近用过（粘贴、替换或复制）的结果，只存在本机，文件仅当前用户可读。
/// 读写和生词本、查词记录共用 `JSONFileStorage`：后台写入，读不懂的文件挪到一边留底。
@MainActor
final class HistoryStore: ObservableObject {
    static let limit = 20

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIInput", isDirectory: true).appendingPathComponent("history.json")
    }

    @Published private(set) var entries: [HistoryEntry] = []
    private let storage: JSONFileStorage<HistoryEntry>

    /// `fileURL` 为 nil 表示只在内存里（测试用）。
    init(fileURL: URL? = HistoryStore.defaultURL) {
        storage = JSONFileStorage(url: fileURL)
        if let legacy = Self.legacyEntries(at: fileURL) {
            // 旧版本直接存一个数组；读进来后按现在的格式重写一遍。
            entries = Array(legacy.prefix(Self.limit))
            storage.save(entries)
        } else {
            entries = Array(storage.load().prefix(Self.limit))
        }
    }

    private static func legacyEntries(at url: URL?) -> [HistoryEntry]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([HistoryEntry].self, from: data)
    }

    func record(source: String,
                result: String,
                mode: TransformMode,
                tone: WritingTone,
                appName: String?,
                date: Date = Date()) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return }
        // 同一条再用一次：移到最前，不重复记录。
        entries.removeAll { $0.source == source && $0.result == result }
        entries.insert(
            HistoryEntry(id: UUID(), date: date, source: source, result: result,
                         mode: mode, tone: tone, appName: appName),
            at: 0
        )
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        storage.save(entries)
    }

    func clear() {
        entries = []
        storage.remove()
    }

    /// 等待排队中的写入完成（测试用）。
    func flush() {
        storage.flush()
    }
}
