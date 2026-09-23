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
    private let webPageService: WebPageService
    private let config: @Sendable () -> ServiceConfig
    private let retryDelays: [TimeInterval]

    init(session: URLSession = .shared,
         webPageService: WebPageService? = nil,
         config: @escaping @Sendable () -> ServiceConfig = { Config.service },
         retryDelays: [TimeInterval] = TranslationService.defaultRetryDelays) {
        self.session = session
        self.webPageService = webPageService ?? WebPageService(session: session)
        self.config = config
        self.retryDelays = retryDelays
    }

    /// 保留旧调用入口，行为等价于“忠实中译英”。
    func translate(_ chinese: String) async throws -> String {
        try await perform(
            TransformationRequest(
                mode: .zhToEnglish,
                tone: .faithful,
                text: chinese
            )
        )
    }

    /// 执行一次转换。文本任务流式返回，`onPartial` 随每个增量收到累计文本；
    /// 网页任务在每段译完后回报进度文档。返回值为清洗后的最终结果。
    func perform(_ request: TransformationRequest,
                 onPartial: PartialHandler? = nil) async throws -> String {
        try Task.checkCancellation()
        switch request.mode {
        case .zhToEnglish, .englishToChinese, .polish:
            return try await stream(TransformationPromptBuilder.make(for: request), onPartial: onPartial)
        case .webPage:
            return try await translateWebPage(request, onPartial: onPartial)
        }
    }

    private func translateWebPage(_ request: TransformationRequest,
                                  onPartial: PartialHandler?) async throws -> String {
        let article = try await webPageService.fetchArticle(from: request.text)
        let chunks = WebPageService.chunk(text: article.body)
        guard !chunks.isEmpty else {
            throw WebPageService.WebPageError.noArticleContent
        }

        var translatedChunks: [String] = []
        translatedChunks.reserveCapacity(chunks.count)
        var translationWarning: String?
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            if let onPartial {
                let progress = Self.webDocument(
                    article: article,
                    notes: ["正在翻译第 \(index + 1)/\(chunks.count) 段…"],
                    summarySection: nil,
                    translatedChunks: translatedChunks
                )
                await onPartial(progress)
            }
            let chunkRequest = TransformationRequest(
                mode: .webPage,
                tone: .faithful,
                text: chunk,
                customInstructions: request.customInstructions
            )
            do {
                translatedChunks.append(
                    try await complete(TransformationPromptBuilder.make(for: chunkRequest))
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !translatedChunks.isEmpty else { throw error }
                translationWarning = "正文翻译在第 \(index + 1)/\(chunks.count) 段中断：\(error.localizedDescription)"
                break
            }
        }

        let summary: String?
        var summaryWarning: String?
        if request.includeSummary, translationWarning == nil {
            if let onPartial {
                await onPartial(Self.webDocument(
                    article: article,
                    notes: ["正在生成摘要…"],
                    summarySection: nil,
                    translatedChunks: translatedChunks
                ))
            }
            do {
                summary = try await summarize(chunks: chunks)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summary = nil
                summaryWarning = "摘要生成失败：\(error.localizedDescription)"
            }
        } else {
            summary = nil
        }

        var notes: [String] = []
        if let translationWarning {
            notes.append("\(translationWarning)；已保留前 \(translatedChunks.count) 段译文。")
        }
        let summarySection = summary ?? summaryWarning
        return Self.webDocument(
            article: article,
            notes: notes,
            summarySection: summarySection,
            translatedChunks: translatedChunks
        )
    }

    private static func webDocument(article: WebArticle,
                                    notes: [String],
                                    summarySection: String?,
                                    translatedChunks: [String]) -> String {
        var sections = ["# \(article.title)", "来源：\(article.sourceURL.absoluteString)"]
        if article.wasTruncated {
            sections.append("提示：网页正文过长，已翻译可安全处理的前 160,000 个字符。")
        }
        sections.append(contentsOf: notes.map { "提示：\($0)" })
        if let summarySection {
            sections.append("## 摘要\n\(summarySection)")
        }
        if !translatedChunks.isEmpty {
            sections.append("## 正文翻译\n\(translatedChunks.joined(separator: "\n\n"))")
        }
        return sections.joined(separator: "\n\n")
    }

    private func summarize(chunks: [String]) async throws -> String {
        var partialSummaries: [String] = []
        partialSummaries.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            partialSummaries.append(
                try await complete(
                    TransformationPromptBuilder.makeChineseSummary(for: chunk)
                )
            )
        }
        guard partialSummaries.count > 1 else {
            return partialSummaries[0]
        }
        return try await complete(
            TransformationPromptBuilder.makeChineseSummary(
                for: partialSummaries.joined(separator: "\n\n")
            )
        )
    }

    private func complete(_ prompt: TransformationPrompt) async throws -> String {
        try await withRetry { _ in
            let request = try self.makeRequest(for: prompt, stream: false)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await self.session.data(for: request)
            } catch {
                throw Self.mapTransportError(error)
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw TranslationError.decode
            }
            Log.flow.notice("request: HTTP \(http.statusCode)")
            let text = try Self.parseResponse(
                data: data,
                statusCode: http.statusCode,
                retryAfter: Self.retryAfter(from: http)
            )
            return Self.clean(text, source: prompt.sourceText)
        }
    }

    private func stream(_ prompt: TransformationPrompt,
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

            let cleaned = Self.clean(text, source: prompt.sourceText)
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

    static func parseResponse(data: Data,
                              statusCode: Int,
                              retryAfter: TimeInterval? = nil) throws -> String {
        guard (200...299).contains(statusCode) else {
            throw TranslationError.badStatus(
                statusCode,
                serviceMessage(from: data),
                retryAfter: retryAfter
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw TranslationError.decode
        }
        if json["stop_reason"] as? String == "max_tokens" {
            throw TranslationError.outputTruncated
        }

        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.decode
        }
        return trimmed
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
