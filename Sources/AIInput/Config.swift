import Foundation

/// 读写应用配置。API Key 的读取顺序：~/.aiinput/key 文件 → 环境变量
/// MINIMAX_API_KEY；设置窗口填写的 key 也写入该文件。
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
        static let autoPaste = "autoPaste"
        static let customInstructions = "customInstructions"
        static let favoriteTones = "favoriteTones"
        static let pinnedPanelOrigins = "pinnedPanelOrigins"
        static let historyEnabled = "historyEnabled"
        static let lookupLogEnabled = "lookupLogEnabled"
        static let hotkey = "hotkey"
        static let backupEnabled = "backupEnabled"
        static let backupModel = "backupModel"
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
            return ""
        }
        set {
            // 只写入 ~/.aiinput/key（仅当前用户可读），不再在偏好设置里留明文副本。
            writeKeyFile(newValue)
        }
    }

    /// 旧版本会把 key 明文存进偏好设置。启动时搬到 key 文件（文件里没有时），然后删除。
    static func migrateLegacyAPIKey() {
        guard let legacy = defaults.string(forKey: Keys.apiKey) else { return }
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileKey = (try? String(contentsOf: keyFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fileKey.isEmpty, !trimmed.isEmpty {
            writeKeyFile(trimmed)
        }
        defaults.removeObject(forKey: Keys.apiKey)
        Log.flow.notice("config: 已移除偏好设置里的明文 API Key")
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

    /// 备用设置以前存在 `droidFallbackEnabled` / `fallbackModel` 下。启动时搬到新键名
    /// （新键已有值就以新键为准），然后删掉旧键。
    static func migrateLegacyBackupKeys(in defaults: UserDefaults = .standard) {
        let renames = ["droidFallbackEnabled": Keys.backupEnabled, "fallbackModel": Keys.backupModel]
        for (old, new) in renames {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
    }

    /// 主服务失败时是否改用本机 droid。
    static var backupEnabled: Bool {
        get { defaults.bool(forKey: Keys.backupEnabled) }
        set { defaults.set(newValue, forKey: Keys.backupEnabled) }
    }

    /// 备用 droid 的模型；留空用 droid 自己的默认模型。
    static var backupModel: String {
        get { defaults.string(forKey: Keys.backupModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.backupModel) }
    }

    static var backup: BackupConfig {
        BackupConfig(enabled: backupEnabled, model: backupModel)
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

    /// 文本任务完成后跳过预览、直接粘贴（旧行为）。默认关闭：先预览再粘贴。
    static var autoPaste: Bool {
        get { defaults.bool(forKey: Keys.autoPaste) }
        set { defaults.set(newValue, forKey: Keys.autoPaste) }
    }

    static let defaultFavoriteTones: [WritingTone] = [.faithful, .concise, .professional, .natural, .friendly]

    /// 面板上直接显示的常用语气（⌘1–⌘5），其余放在「更多」里。
    static var favoriteTones: [WritingTone] {
        get {
            let stored = (defaults.stringArray(forKey: Keys.favoriteTones) ?? [])
                .compactMap(WritingTone.init)
            return stored.isEmpty ? defaultFavoriteTones : Array(stored.prefix(5))
        }
        set { defaults.set(newValue.prefix(5).map(\.rawValue), forKey: Keys.favoriteTones) }
    }

    /// 用户拖动面板后记住的位置（每块显示器一个左上角）。
    static func pinnedPanelOrigin(forDisplay display: String) -> CGPoint? {
        let all = defaults.dictionary(forKey: Keys.pinnedPanelOrigins) as? [String: [Double]]
        guard let values = all?[display], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    static func setPinnedPanelOrigin(_ origin: CGPoint, forDisplay display: String) {
        var all = defaults.dictionary(forKey: Keys.pinnedPanelOrigins) as? [String: [Double]] ?? [:]
        all[display] = [Double(origin.x), Double(origin.y)]
        defaults.set(all, forKey: Keys.pinnedPanelOrigins)
    }

    static func clearPinnedPanelOrigins() {
        defaults.removeObject(forKey: Keys.pinnedPanelOrigins)
    }

    static var hotkey: Hotkey {
        get {
            defaults.data(forKey: Keys.hotkey)
                .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.hotkey) }
    }

    /// 是否记录用过的结果（⌘Y 历史）。
    static var historyEnabled: Bool {
        get { defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.historyEnabled) }
    }

    /// 是否自动记录打开过的学习卡片（「第 N 次查」和学习统计的依据）。
    static var lookupLogEnabled: Bool {
        get { defaults.object(forKey: Keys.lookupLogEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.lookupLogEnabled) }
    }

    /// 个人要求 / 术语表，追加到每次请求的系统提示。
    static var customInstructions: String {
        get { defaults.string(forKey: Keys.customInstructions) ?? "" }
        set { defaults.set(newValue, forKey: Keys.customInstructions) }
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
