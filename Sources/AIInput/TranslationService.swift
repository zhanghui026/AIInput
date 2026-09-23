import Foundation

/// Anthropic Messages 兼容客户端，以及文本/网页任务的编排入口。
final class TranslationService: @unchecked Sendable {
    enum TranslationError: LocalizedError {
        case notConfigured
        case invalidBaseURL(String)
        case badStatus(Int, String)
        case decode
        case outputTruncated
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "未配置 API Key 或模型，请到设置中填写。"
            case .invalidBaseURL(let value):
                return "Base URL 无效：\(value)"
            case .badStatus(let code, let body):
                return "请求失败（\(code)）：\(body)"
            case .decode:
                return "无法解析服务端响应。"
            case .outputTruncated:
                return "模型输出达到长度上限，未返回完整内容。请缩短输入后重试。"
            case .transport(let error):
                return "网络错误：\(error.localizedDescription)"
            }
        }
    }

    private let session: URLSession
    private let webPageService: WebPageService

    init(session: URLSession = .shared, webPageService: WebPageService? = nil) {
        self.session = session
        self.webPageService = webPageService ?? WebPageService(session: session)
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

    func perform(_ request: TransformationRequest) async throws -> String {
        try Task.checkCancellation()
        switch request.mode {
        case .zhToEnglish, .englishToChinese, .polish:
            return try await complete(TransformationPromptBuilder.make(for: request))
        case .webPage:
            return try await translateWebPage(request)
        }
    }

    private func translateWebPage(_ request: TransformationRequest) async throws -> String {
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
            let chunkRequest = TransformationRequest(
                mode: .webPage,
                tone: .faithful,
                text: chunk
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

        var sections = ["# \(article.title)", "来源：\(article.sourceURL.absoluteString)"]
        if article.wasTruncated {
            sections.append("提示：网页正文过长，已翻译可安全处理的前 160,000 个字符。")
        }
        if let translationWarning {
            sections.append("提示：\(translationWarning)；已保留前 \(translatedChunks.count) 段译文。")
        }
        if let summary {
            sections.append("## 摘要\n\(summary)")
        } else if let summaryWarning {
            sections.append("## 摘要\n\(summaryWarning)")
        }
        sections.append("## 正文翻译\n\(translatedChunks.joined(separator: "\n\n"))")
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
        let key = Config.apiKey
        let model = Config.model
        guard !key.isEmpty, !model.isEmpty else {
            throw TranslationError.notConfigured
        }

        let url = try messagesURL(from: Config.baseUrl)
        Log.flow.notice(
            "request: POST \(url.absoluteString, privacy: .public) model=\(model, privacy: .public)"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = prompt.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": prompt.maxTokens,
            "system": prompt.system,
            "messages": [
                ["role": "user", "content": prompt.user],
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw TranslationError.transport(error)
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.decode
        }
        Log.flow.notice("request: HTTP \(http.statusCode)")
        let text = try Self.parseResponse(data: data, statusCode: http.statusCode)
        return Self.clean(text, source: prompt.sourceText)
    }

    static func parseResponse(data: Data, statusCode: Int) throws -> String {
        guard (200...299).contains(statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.badStatus(statusCode, String(responseText.prefix(800)))
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
