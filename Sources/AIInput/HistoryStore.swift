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
@MainActor
final class HistoryStore: ObservableObject {
    static let limit = 20

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIInput", isDirectory: true).appendingPathComponent("history.json")
    }

    @Published private(set) var entries: [HistoryEntry] = []
    /// nil 表示只在内存里（测试用）。
    private let fileURL: URL?

    init(fileURL: URL? = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([HistoryEntry].self, from: data) {
            entries = Array(decoded.prefix(Self.limit))
        }
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
        save()
    }

    func clear() {
        entries = []
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.flow.error("history: 保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // 默认日期编码是浮点秒数，能精确还原（ISO 8601 会丢掉小数秒）。
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
