import Foundation

struct WebArticle: Equatable, Sendable {
    let sourceURL: URL
    let title: String
    let body: String
    let wasTruncated: Bool
}

final class WebPageService {
    enum WebPageError: LocalizedError {
        case invalidURL
        case unsupportedResponse
        case badStatus(Int)
        case pageTooLarge
        case unreadableText
        case noArticleContent
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "请输入有效的 HTTPS 网页链接。"
            case .unsupportedResponse:
                return "链接返回的不是可读取的 HTML 网页。"
            case .badStatus(let status):
                return "网页请求失败（\(status)）。"
            case .pageTooLarge:
                return "网页文件过大，无法安全处理。"
            case .unreadableText:
                return "无法读取网页文本编码。"
            case .noArticleContent:
                return "未提取到网页正文；该页面可能需要登录或依赖 JavaScript 加载。"
            case .transport(let error):
                return "网页加载失败：\(error.localizedDescription)"
            }
        }
    }

    private static let maximumDownloadBytes = 5 * 1_024 * 1_024
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchArticle(from rawURL: String) async throws -> WebArticle {
        let url = try Self.validatedHTTPSURL(from: rawURL)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 AIInput/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml;q=0.9", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw WebPageError.transport(error)
        }

        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw WebPageError.unsupportedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WebPageError.badStatus(http.statusCode)
        }
        guard data.count <= Self.maximumDownloadBytes else {
            throw WebPageError.pageTooLarge
        }
        if let mimeType = http.mimeType?.lowercased(),
           mimeType != "text/html",
           mimeType != "application/xhtml+xml" {
            throw WebPageError.unsupportedResponse
        }
        guard let html = Self.decodeHTML(data, textEncodingName: http.textEncodingName) else {
            throw WebPageError.unreadableText
        }
        return try HTMLArticleExtractor.extract(html: html, sourceURL: http.url ?? url)
    }

    static func validatedHTTPSURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw WebPageError.invalidURL
        }
        components.fragment = nil
        guard let url = components.url else {
            throw WebPageError.invalidURL
        }
        return url
    }

    static func chunk(text: String, maxCharacters: Int = 12_000) -> [String] {
        guard maxCharacters > 0 else { return [] }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var current = ""

        func appendCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = ""
        }

        for paragraph in paragraphs {
            if paragraph.count > maxCharacters {
                appendCurrent()
                var remainder = paragraph[...]
                while !remainder.isEmpty {
                    let end = remainder.index(
                        remainder.startIndex,
                        offsetBy: min(maxCharacters, remainder.count)
                    )
                    chunks.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                continue
            }

            let candidateLength = current.isEmpty
                ? paragraph.count
                : current.count + 2 + paragraph.count
            if candidateLength <= maxCharacters {
                current += current.isEmpty ? paragraph : "\n\n\(paragraph)"
            } else {
                appendCurrent()
                current = paragraph
            }
        }
        appendCurrent()
        return chunks
    }

    private static func decodeHTML(_ data: Data, textEncodingName: String?) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let encoding: String.Encoding
        switch textEncodingName?.lowercased() {
        case "iso-8859-1", "latin1":
            encoding = .isoLatin1
        case "windows-1252", "cp1252":
            encoding = .windowsCP1252
        case "us-ascii":
            encoding = .ascii
        default:
            encoding = .utf8
        }
        return String(data: data, encoding: encoding)
    }
}

enum HTMLArticleExtractor {
    private static let maximumExtractedCharacters = 160_000

    static func extract(html: String, sourceURL: URL) throws -> WebArticle {
        let title = extractFirst(tag: "title", from: html)
            .map(plainText(from:))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? sourceURL.host ?? "网页"

        var cleanedHTML = replacing(
            pattern: #"<!--[\s\S]*?-->"#,
            in: html,
            with: " "
        )
        for tag in ["script", "style", "noscript", "svg", "canvas", "template",
                    "nav", "header", "footer", "aside", "form"] {
            cleanedHTML = replacing(
                pattern: #"<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)\s*>"#,
                in: cleanedHTML,
                with: " "
            )
        }

        let candidate = extractFirst(tag: "article", from: cleanedHTML)
            ?? extractFirst(tag: "main", from: cleanedHTML)
            ?? extractFirst(tag: "body", from: cleanedHTML)
            ?? cleanedHTML
        let extracted = plainText(from: candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extracted.isEmpty else {
            throw WebPageService.WebPageError.noArticleContent
        }

        let wasTruncated = extracted.count > maximumExtractedCharacters
        let body = wasTruncated
            ? String(extracted.prefix(maximumExtractedCharacters))
            : extracted
        return WebArticle(
            sourceURL: sourceURL,
            title: title,
            body: body,
            wasTruncated: wasTruncated
        )
    }

    private static func extractFirst(tag: String, from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\#(tag)\b[^>]*>([\s\S]*?)</\#(tag)\s*>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[contentRange])
    }

    private static func plainText(from html: String) -> String {
        var text = replacing(
            pattern: #"<(?:br|hr)\b[^>]*?/?>"#,
            in: html,
            with: "\n\n"
        )
        text = replacing(
            pattern: #"</?(?:address|article|blockquote|div|dl|fieldset|figcaption|figure|h[1-6]|li|main|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul)\b[^>]*>"#,
            in: text,
            with: "\n\n"
        )
        text = replacing(pattern: #"<[^>]+>"#, in: text, with: " ")
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let paragraphs = text.components(separatedBy: .newlines)
            .map {
                replacing(pattern: #"[ \t\u{00A0}]+"#, in: $0, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        let named: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
            "&ndash;": "–",
            "&mdash;": "—",
            "&hellip;": "…",
            "&copy;": "©",
            "&reg;": "®",
        ]
        var decoded = value
        for (entity, replacement) in named {
            decoded = decoded.replacingOccurrences(
                of: entity,
                with: replacement,
                options: [.caseInsensitive]
            )
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"&#(x[0-9a-f]+|[0-9]+);"#,
            options: [.caseInsensitive]
        ) else {
            return decoded
        }
        let matches = regex.matches(
            in: decoded,
            range: NSRange(decoded.startIndex..., in: decoded)
        )
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: decoded),
                  let numberRange = Range(match.range(at: 1), in: decoded) else {
                continue
            }
            let number = String(decoded[numberRange])
            let radix = number.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(number.dropFirst()) : number
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            decoded.replaceSubrange(wholeRange, with: String(scalar))
        }
        return decoded
    }

    private static func replacing(
        pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}
