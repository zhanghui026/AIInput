import Foundation

/// 备用配置快照：主服务失败时是否改用本机 droid，以及它用的模型（留空用默认）。
struct FallbackConfig: Sendable, Equatable {
    let enabled: Bool
    let model: String

    static let disabled = FallbackConfig(enabled: false, model: "")
}

/// 主服务失败后的备用通道（生产环境是 `DroidFallback`，测试里可替换）。
protocol TextFallback: Sendable {
    /// 当前是否启用；未启用时直接报告主服务的错误。
    var isEnabled: Bool { get }
    func run(_ prompt: TransformationPrompt) async throws -> String
}

/// 通过本机 `droid exec` 的非交互模式完成一次转换。
struct DroidFallback: TextFallback {
    enum DroidError: LocalizedError {
        case notFound
        case failed(Int32, String)
        case timedOut
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "找不到 droid 命令，请确认已安装并在登录 shell 的 PATH 里。"
            case .failed(let status, let message):
                let detail = message.isEmpty ? "" : "：\(message)"
                return "Droid 退出码 \(status)\(detail)"
            case .timedOut:
                return "Droid 超时未返回（可能需要先在终端里登录一次）。"
            case .emptyOutput:
                return "Droid 没有返回内容。"
            }
        }
    }

/// Agent CLI 冷启动慢，比直连接口宽限得多。
    static let timeout: TimeInterval = 120

    let config: @Sendable () -> FallbackConfig

    init(config: @escaping @Sendable () -> FallbackConfig = { Config.fallback }) {
        self.config = config
    }

    var isEnabled: Bool { config().enabled }

    func run(_ prompt: TransformationPrompt) async throws -> String {
        let config = config()
        guard config.enabled else {
            throw TranslationService.TranslationError.notConfigured
        }
        let environment = await ShellEnvironment.shared.value()
        guard let executable = ShellEnvironment.locate("droid", in: environment) else {
            throw DroidError.notFound
        }
        Log.flow.notice("fallback: droid model=\(config.model, privacy: .public)")
        let started = Date()
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: Self.arguments(prompt: Self.combine(prompt), model: config.model),
            environment: environment,
            timeout: min(max(prompt.timeout, Self.timeout), 300)
        )
        if result.timedOut {
            throw DroidError.timedOut
        }
        guard result.status == 0 else {
            throw DroidError.failed(result.status, Self.lastLine(of: result.stderr))
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw DroidError.emptyOutput
        }
        let elapsed = Date().timeIntervalSince(started)
        Log.flow.notice("fallback: 完成 \(elapsed, format: .fixed(precision: 1))s")
        return output
    }

    /// 一次性调用参数。不加 --auto 时 droid exec 只读，不会改动文件或跑命令。
    static func arguments(prompt: String, model: String) -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["exec"]
        if !model.isEmpty { args += ["-m", model] }
        return args + [prompt]
    }

    /// droid 只收一段提示词：把系统提示放前面，并要求它别动用工具。
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
        // 空的临时目录：子进程看不到任何项目文件。
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // 不接 stdin，免得子进程一直等输入。
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
