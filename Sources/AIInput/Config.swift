import Foundation

/// 读写应用配置。API Key 的读取顺序：~/.aiinput/key 文件 → 环境变量
/// MINIMAX_API_KEY → UserDefaults（设置窗口手动填写）。
/// 注意：通过 Finder 双击启动的 GUI App 拿不到 shell 环境变量，故推荐把 key
/// 写入 ~/.aiinput/key（见 README 的安装步骤），App 启动时读取该文件。
enum Config {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let apiKey = "apiKey"
        static let baseUrl = "baseUrl"
        static let model = "model"
    }

    /// 环境变量名（仅在从终端启动时可用）。
    private static let envApiKey = "MINIMAX_API_KEY"

    /// key 文件路径：~/.aiinput/key
    private static var keyFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".aiinput", isDirectory: true)
            .appendingPathComponent("key")
    }

    static var apiKey: String {
        get {
            // 1. 配置文件
            if let f = try? String(contentsOf: keyFileURL, encoding: .utf8) {
                let trimmed = f.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            // 2. 环境变量（终端启动时）
            if let env = ProcessInfo.processInfo.environment[envApiKey], !env.isEmpty {
                return env
            }
            // 3. UserDefaults
            return defaults.string(forKey: Keys.apiKey) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.apiKey)
            // 同步写入文件，便于双击启动时使用。
            writeKeyFile(newValue)
        }
    }

    /// 把 key 写入 ~/.aiinput/key，权限设为 600。
    private static func writeKeyFile(_ value: String) {
        let dir = keyFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        try? value.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8)?
            .write(to: keyFileURL, options: .atomic)
        // 限制仅当前用户可读写。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
    }

    /// Anthropic 兼容接口的 base URL，不带尾部斜杠，也不带 /v1/messages。
    /// MiniMax 的 Anthropic 兼容端点为 https://api.minimaxi.com/anthropic/v1/messages。
    static var baseUrl: String {
        get {
            let v = defaults.string(forKey: Keys.baseUrl) ?? ""
            return v.isEmpty ? "https://api.minimaxi.com/anthropic/v1" : v
        }
        set { defaults.set(newValue, forKey: Keys.baseUrl) }
    }

    static var model: String {
        get {
            let v = defaults.string(forKey: Keys.model) ?? ""
            return v.isEmpty ? "MiniMax-M3" : v
        }
        set { defaults.set(newValue, forKey: Keys.model) }
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty
    }
}
