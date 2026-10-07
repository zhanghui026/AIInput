import Foundation

/// 本地 JSON 文件：顶层带 `schemaVersion`，读取时跳过坏掉的单条，写入在后台串行队列里完成
/// （文件只有当前用户可读）。生词本、查词记录共用。
final class JSONFileStorage<Item: Codable & Sendable>: @unchecked Sendable {
    static var currentSchemaVersion: Int { 1 }

    static func defaultURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIInput", isDirectory: true).appendingPathComponent(name)
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var items: [Item]
    }

    private struct LossyEnvelope: Decodable {
        var items: [Lossy<Item>]
    }

    /// nil 表示只在内存里（测试用）。
    private let url: URL?
    private let queue = DispatchQueue(label: "com.zhanghui.aiinput.storage", qos: .utility)

    init(url: URL?) {
        self.url = url
    }

    func load() -> [Item] {
        guard let url, let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(LossyEnvelope.self, from: data) else {
            return []
        }
        return envelope.items.compactMap(\.value)
    }

    func save(_ items: [Item]) {
        guard let url else { return }
        queue.async {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Envelope(schemaVersion: Self.currentSchemaVersion, items: items))
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.flow.error("storage: 保存 \(url.lastPathComponent, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove() {
        guard let url else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// 等待排队中的写入完成（测试用）。
    func flush() {
        queue.sync {}
    }
}
