import Foundation

/// 主模型服务失败时改用的本机 Agent CLI。
enum FallbackCLI: String, CaseIterable, Sendable {
    case codex
    case droid
    case agy

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .droid: return "Droid"
        case .agy: return "agy"
        }
    }

    /// 非交互、只读、不落会话的一次性调用参数。各家默认都会给 Agent 工具权限，
    /// 这里尽量收窄：codex 只读沙箱；droid 不加 --auto 即只读；agy 不跳过权限确认。
    func arguments(prompt: String, model: String) -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .codex:
            var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never"]
            if !model.isEmpty { args += ["-m", model] }
            return args + [prompt]
        case .droid:
            var args = ["exec"]
            if !model.isEmpty { args += ["-m", model] }
            return args + [prompt]
        case .agy:
            var args = ["-p", prompt, "--disable-slash-commands"]
            if !model.isEmpty { args += ["--model", model] }
            return args
        }
    }
}

/// 备用 CLI 配置快照；`cli == nil` 表示不使用备用。
struct FallbackConfig: Sendable, Equatable {
    let cli: FallbackCLI?
    let model: String

    static let disabled = FallbackConfig(cli: nil, model: "")
}

/// 主服务失败后的备用通道（生产环境是 `CLIFallback`，测试里可替换）。
protocol TextFallback: Sendable {
    /// 当前是否启用；未启用时直接报告主服务的错误。
    var isEnabled: Bool { get }
    func run(_ prompt: TransformationPrompt) async throws -> String
}

/// 通过本机 codex / droid / agy 的非交互模式完成一次转换。
struct CLIFallback: TextFallback {
    enum CLIError: LocalizedError {
        case notFound(FallbackCLI)
        case failed(FallbackCLI, Int32, String)
        case timedOut(FallbackCLI)
        case emptyOutput(FallbackCLI)

        var errorDescription: String? {
            switch self {
            case .notFound(let cli):
                return "找不到 \(cli.rawValue) 命令，请确认已安装并在登录 shell 的 PATH 里。"
            case .failed(let cli, let status, let message):
                let detail = message.isEmpty ? "" : "：\(message)"
                return "\(cli.displayName) 退出码 \(status)\(detail)"
            case .timedOut(let cli):
                return "\(cli.displayName) 超时未返回（可能需要先在终端里登录一次）。"
            case .emptyOutput(let cli):
                return "\(cli.displayName) 没有返回内容。"
            }
        }
    }

    /// Agent CLI 冷启动慢，比直连接口宽限得多。
    static let timeout: TimeInterval = 120

    let config: @Sendable () -> FallbackConfig

    init(config: @escaping @Sendable () -> FallbackConfig = { Config.fallback }) {
        self.config = config
    }

    var isEnabled: Bool { config().cli != nil }

    func run(_ prompt: TransformationPrompt) async throws -> String {
        let config = config()
        guard let cli = config.cli else {
            throw TranslationService.TranslationError.notConfigured
        }
        let environment = await ShellEnvironment.shared.value()
        guard let executable = ShellEnvironment.locate(cli.rawValue, in: environment) else {
            throw CLIError.notFound(cli)
        }
        Log.flow.notice("fallback: \(cli.rawValue, privacy: .public) model=\(config.model, privacy: .public)")
        let started = Date()
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: cli.arguments(prompt: Self.combine(prompt), model: config.model),
            environment: environment,
            timeout: min(max(prompt.timeout, Self.timeout), 300)
        )
        if result.timedOut {
            throw CLIError.timedOut(cli)
        }
        guard result.status == 0 else {
            throw CLIError.failed(cli, result.status, Self.lastLine(of: result.stderr))
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw CLIError.emptyOutput(cli)
        }
        let elapsed = Date().timeIntervalSince(started)
        Log.flow.notice("fallback: 完成 \(elapsed, format: .fixed(precision: 1))s")
        return output
    }

    /// CLI 只收一段提示词：把系统提示放前面，并要求它别动用工具。
    static func combine(_ prompt: TransformationPrompt) -> String {
        """
        \(prompt.system)

        Answer directly in this reply. Do not run commands, read or write files, or use any tools.

        \(prompt.user)
        """
    }

    private static func lastLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        return String(line.prefix(200))
    }
}

/// GUI App 从 Finder 启动时只有极简的 PATH，nvm、~/.local/bin 之类都不在里面。
/// 第一次需要时跑一次用户的交互式登录 shell，取它导出的环境变量，之后复用。
actor ShellEnvironment {
    static let shared = ShellEnvironment()

    private var cached: [String: String]?

    func value() async -> [String: String] {
        if let cached { return cached }
        let loaded = await Self.load()
        cached = loaded
        return loaded
    }

    private static let marker = "__AIINPUT_ENV__"

    private static func load() async -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // 启动脚本可能往 stdout 打印东西，用标记把 env 的输出圈出来。
        let script = "printf '\(marker)'; env -0; printf '\(marker)'"
        let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-ilc", script],
            environment: base,
            timeout: 10
        )
        if let stdout = result?.stdout {
            let parts = stdout.components(separatedBy: marker)
            if parts.count >= 3 {
                for entry in parts[1].split(separator: "\0") {
                    guard let eq = entry.firstIndex(of: "=") else { continue }
                    base[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
                }
            }
        }
        if base["PATH"].map({ !$0.contains(".local/bin") }) ?? true {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            base["PATH"] = (extra + [base["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        }
        return base
    }

    /// 在 PATH 里找可执行文件。
    nonisolated static func locate(_ name: String, in environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let path = (String(dir) as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

/// 跑一个子进程并收集输出；任务取消或超时都会结束它。
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    static func run(executable: URL,
                    arguments: [String],
                    environment: [String: String],
                    timeout: TimeInterval) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // 空的临时目录：CLI 看不到任何项目文件。
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // 不接 stdin：codex 等会一直等 stdin 读完。
        process.standardInput = FileHandle.nullDevice

        let state = RunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                process.terminationHandler = { _ in group.leave() }

                do {
                    try process.run()
                } catch {
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                state.started(process)

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        state.markTimedOut()
                        process.terminate()
                    }
                }
                group.notify(queue: .global()) {
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self),
                        timedOut: state.timedOut
                    ))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var didTimeOut = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var isCancelled: Bool { locked { cancelled } }
    var timedOut: Bool { locked { didTimeOut } }

    func started(_ process: Process) {
        let alreadyCancelled = locked {
            self.process = process
            return cancelled
        }
        if alreadyCancelled { process.terminate() }
    }

    func markTimedOut() { locked { didTimeOut = true } }

    func cancel() {
        let process = locked {
            cancelled = true
            return self.process
        }
        if let process, process.isRunning { process.terminate() }
    }
}
