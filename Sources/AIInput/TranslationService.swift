import Foundation

/// Anthropic Messages 兼容客户端，以及文本/网页任务的编排入口。
final class TranslationService: @unchecked Sendable {
    enum TranslationError: LocalizedError {
        case notConfigured
        case invalidBaseURL(String)
        case badStatus(Int, String, retryAfter: TimeInterval?)
        case decode
        case outputTruncated
        case transport(Error)
        case fallbackFailed(primary: Error, fallback: Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "未配置 API Key 或模型，请到设置中填写。"
            case .invalidBaseURL(let value):
                return "Base URL 无效：\(value)"
            case .badStatus(let code, let message, _):
                let detail = message.isEmpty ? "" : "：\(message)"
                switch code {
                case 401, 403:
                    return "API Key 无效或无权限（\(code)）\(detail)"
                case 429:
                    return "请求太频繁或额度不足（429）\(detail)"
                case 500...599:
                    return "模型服务暂时不可用（\(code)），已自动重试\(detail)"
                default:
                    return "请求失败（\(code)）\(detail)"
                }
            case .decode:
                return "无法解析服务端响应。"
            case .outputTruncated:
                return "模型输出达到长度上限，未返回完整内容。请缩短输入后重试。"
            case .transport(let error):
                return "网络错误：\(error.localizedDescription)"
            case .fallbackFailed(let primary, let fallback):
                return "\(primary.localizedDescription)\n备用也失败：\(fallback.localizedDescription)"
            }
        }
    }

    /// 流式结果回调：参数是截至目前的完整文本（不是增量）。
    typealias PartialHandler = @MainActor (String) -> Void

    static let defaultRetryDelays: [TimeInterval] = [0.6, 1.5]
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
    private static let retryableURLErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    private let session: URLSession
    private let config: @Sendable () -> ServiceConfig
    private let retryDelays: [TimeInterval]
    private let fallback: TextFallback?

    init(session: URLSession = .shared,
         config: @escaping @Sendable () -> ServiceConfig = { Config.service },
         retryDelays: [TimeInterval] = TranslationService.defaultRetryDelays,
         fallback: TextFallback? = CLIFallback()) {
        self.session = session
        self.config = config
        self.retryDelays = retryDelays
        self.fallback = fallback
    }

    /// 执行一次转换并流式返回：`onPartial` 随每个增量收到累计文本，
    /// 返回值为清洗后的最终结果。
    func perform(_ request: TransformationRequest,
                 onPartial: PartialHandler? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await stream(TransformationPromptBuilder.make(for: request), onPartial: onPartial)
    }

    /// 流式取回模型的原始输出，不做引号清洗（卡片的 JSON 不能被清洗改动）。
    func performRaw(_ prompt: TransformationPrompt,
                    onPartial: PartialHandler? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await stream(prompt, cleansOutput: false, onPartial: onPartial)
    }

    /// 主服务失败（含未配置）且还没向界面输出文字时，改用备用 CLI 一次性取回结果；
    /// 两边都失败时报告两边的原因。
    private func stream(_ prompt: TransformationPrompt,
                        cleansOutput: Bool = true,
                        onPartial: PartialHandler?) async throws -> String {
        let shown = StreamProgress()
        do {
            return try await streamPrimary(prompt, cleansOutput: cleansOutput, shown: shown, onPartial: onPartial)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            guard !shown.started, let fallback, fallback.isEnabled else {
                throw error
            }
            Log.flow.notice("request: 主服务失败，改用备用 CLI：\(error.localizedDescription, privacy: .public)")
            let text: String
            do {
                text = try await fallback.run(prompt)
            } catch let fallbackError {
                if fallbackError is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                throw TranslationError.fallbackFailed(primary: error, fallback: fallbackError)
            }
            try Task.checkCancellation()
            let cleaned = cleansOutput ? Self.clean(text, source: prompt.sourceText) : text
            guard !cleaned.isEmpty else {
                throw TranslationError.decode
            }
            if let onPartial {
                await onPartial(cleaned)
            }
            return cleaned
        }
    }

    private func streamPrimary(_ prompt: TransformationPrompt,
                               cleansOutput: Bool,
                               shown: StreamProgress,
                               onPartial: PartialHandler?) async throws -> String {
        try await withRetry { progress in
            let request = try self.makeRequest(for: prompt, stream: true)
            let started = Date()
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await self.session.bytes(for: request)
            } catch {
                throw Self.mapTransportError(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw TranslationError.decode
            }
            Log.flow.notice("request: HTTP \(http.statusCode) (stream)")
            guard (200...299).contains(http.statusCode) else {
                var body = Data()
                do {
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count >= 4_096 { break }
                    }
                } catch {
                    // 错误体读不完整不影响报告状态码。
                }
                throw TranslationError.badStatus(
                    http.statusCode,
                    Self.serviceMessage(from: body),
                    retryAfter: Self.retryAfter(from: http)
                )
            }

            var text = ""
            do {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    switch try SSEParser.parse(line: line) {
                    case .text(let delta):
                        if text.isEmpty {
                            let latency = Date().timeIntervalSince(started)
                            Log.flow.notice("request: 首字延迟 \(latency, format: .fixed(precision: 2))s")
                        }
                        text += delta
                        if !text.isEmpty {
                            progress.started = true
                            shown.started = true
                        }
                        if let onPartial {
                            await onPartial(text)
                        }
                    case .stop:
                        break
                    case nil:
                        continue
                    }
                }
            } catch let error as TranslationError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.mapTransportError(error)
            }
            try Task.checkCancellation()

            let cleaned = cleansOutput
                ? Self.clean(text, source: prompt.sourceText)
                : text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw TranslationError.decode
            }
            return cleaned
        }
    }

    /// 输出开始前的可重试失败（限流、过载、网关错误、瞬时网络错误）按退避重试；
    /// 一旦已向界面输出文字就不再重试，避免结果闪回重来。
    private func withRetry<T>(_ operation: (StreamProgress) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            let progress = StreamProgress()
            do {
                return try await operation(progress)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                guard !progress.started,
                      attempt < retryDelays.count,
                      let delay = retryDelay(for: error, attempt: attempt) else {
                    throw error
                }
                Log.flow.notice("request: 第 \(attempt + 1) 次重试，等待 \(delay, format: .fixed(precision: 1))s：\(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        switch error as? TranslationError {
        case .badStatus(let code, _, let retryAfter)? where Self.retryableStatusCodes.contains(code):
            return min(retryAfter ?? retryDelays[attempt], 5)
        case .transport(let underlying)?:
            guard let urlError = underlying as? URLError,
                  Self.retryableURLErrors.contains(urlError.code) else {
                return nil
            }
            return retryDelays[attempt]
        default:
            return nil
        }
    }

    private func makeRequest(for prompt: TransformationPrompt, stream: Bool) throws -> URLRequest {
        let config = config()
        guard !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw TranslationError.notConfigured
        }
        let url = try messagesURL(from: config.baseURL)
        Log.flow.notice(
            "request: POST \(url.absoluteString, privacy: .public) model=\(config.model, privacy: .public) stream=\(stream)"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = prompt.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": prompt.maxTokens,
            "system": prompt.system,
            "messages": [
                ["role": "user", "content": prompt.user],
            ],
        ]
        if stream {
            body["stream"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return TranslationError.transport(error)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
    }

    /// 从错误响应体里提取人能看懂的一句话，而不是整段 JSON。
    static func serviceMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let base = json["base_resp"] as? [String: Any],
               let message = base["status_msg"] as? String, !message.isEmpty {
                return message
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(200))
    }

    private func messagesURL(from rawBaseURL: String) throws -> URL {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw TranslationError.invalidBaseURL(trimmed)
        }

        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix("/messages") {
            path.removeLast("/messages".count)
        }
        components.percentEncodedPath = path

        guard let base = components.url else {
            throw TranslationError.invalidBaseURL(trimmed)
        }
        return base.appendingPathComponent("messages")
    }

    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""),
        ("\u{201C}", "\u{201D}"),
        ("\u{2018}", "\u{2019}"),
        ("\u{300C}", "\u{300D}"),
    ]

    /// 模型偶尔会把整段结果包一层引号。仅当整段恰好被一对引号包裹、内部不再
    /// 出现同种引号、且原文本身不以引号开头时剥掉这一层；其余引号都属于内容。
    static func clean(_ value: String, source: String?) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2,
              let first = text.first,
              let last = text.last,
              let pair = quotePairs.first(where: { $0.open == first && $0.close == last }) else {
            return text
        }
        if let sourceFirst = source?.trimmingCharacters(in: .whitespacesAndNewlines).first,
           quotePairs.contains(where: { $0.open == sourceFirst }) {
            return text
        }
        let inner = text.dropFirst().dropLast()
        guard !inner.contains(pair.open), !inner.contains(pair.close) else {
            return text
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 标记本次尝试是否已经向界面输出过文字。
private final class StreamProgress: @unchecked Sendable {
    var started = false
}
