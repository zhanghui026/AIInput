import Foundation

/// 读写应用配置。API Key 的读取顺序：~/.aiinput/key 文件 → 环境变量
/// MINIMAX_API_KEY → UserDefaults（设置窗口手动填写）。
/// 注意：通过 Finder 双击启动的 GUI App 拿不到 shell 环境变量，故推荐把 key
/// 写入 ~/.aiinput/key（见 README 的安装步骤），App 启动时读取该文件。
enum Config {
    private static var defaults: UserDefaults { .standard }

    private enum Keys {
        static let apiKey = "apiKey"
        static let baseUrl = "baseUrl"
        static let model = "model"
        static let panelMode = "panelMode"
        static let direction = "translationDirection"
        static let tone = "writingTone"
        static let includeSummary = "includeSummary"
        static let autoPaste = "autoPaste"
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

    // MARK: - 面板偏好（重启后保留）

    static var panelMode: PanelMode {
        get { defaults.string(forKey: Keys.panelMode).flatMap(PanelMode.init) ?? .translate }
        set { defaults.set(newValue.rawValue, forKey: Keys.panelMode) }
    }

    static var direction: TranslationDirection {
        get { defaults.string(forKey: Keys.direction).flatMap(TranslationDirection.init) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.direction) }
    }

    static var tone: WritingTone {
        get { defaults.string(forKey: Keys.tone).flatMap(WritingTone.init) ?? .faithful }
        set { defaults.set(newValue.rawValue, forKey: Keys.tone) }
    }

    static var includeSummary: Bool {
        get { defaults.object(forKey: Keys.includeSummary) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.includeSummary) }
    }

    /// 文本任务完成后跳过预览、直接粘贴（旧行为）。默认关闭：先预览再粘贴。
    static var autoPaste: Bool {
        get { defaults.bool(forKey: Keys.autoPaste) }
        set { defaults.set(newValue, forKey: Keys.autoPaste) }
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty
    }

    static var service: ServiceConfig {
        ServiceConfig(apiKey: apiKey, baseURL: baseUrl, model: model)
    }
}

/// 单次请求使用的模型服务配置快照。
struct ServiceConfig: Sendable, Equatable {
    let apiKey: String
    let baseURL: String
    let model: String
}
