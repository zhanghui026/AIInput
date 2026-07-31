import Darwin
import Foundation

struct WebArticle: Equatable, Sendable {
    let sourceURL: URL
    let title: String
    let body: String
    let wasTruncated: Bool
}

final class WebPageService: @unchecked Sendable {
    enum WebPageError: LocalizedError {
        case invalidURL
        case unsafeDestination
        case unsupportedResponse
        case badStatus(Int)
        case pageTooLarge
        case unreadableText
        case noArticleContent
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "请输入有效的网页链接。"
            case .unsafeDestination:
                return "为保护本机数据，不能读取本机、局域网或非 HTTPS 目标。"
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

    static let maximumDownloadBytes = 5 * 1_024 * 1_024
    private let session: URLSession
    private let validatesConnectedAddresses: Bool

    init(
        session: URLSession = .shared,
        validatesConnectedAddresses: Bool = true
    ) {
        self.session = session
        self.validatesConnectedAddresses = validatesConnectedAddresses
    }

    func fetchArticle(from rawURL: String) async throws -> WebArticle {
        let url = try Self.validatedHTTPSURL(from: rawURL)
        try Self.validatePublicDestination(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 AIInput/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml;q=0.9", forHTTPHeaderField: "Accept")

        do {
            let redirectGuard = SafeRedirectDelegate()
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectGuard
            )
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw WebPageError.unsupportedResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw WebPageError.badStatus(http.statusCode)
            }
            guard let finalURL = http.url,
                  finalURL.scheme?.lowercased() == "https" else {
                throw WebPageError.unsafeDestination
            }
            try Self.validatePublicDestination(finalURL)
            if let mimeType = http.mimeType?.lowercased(),
               mimeType != "text/html",
               mimeType != "application/xhtml+xml" {
                throw WebPageError.unsupportedResponse
            }
            if response.expectedContentLength > Int64(Self.maximumDownloadBytes) {
                throw WebPageError.pageTooLarge
            }

            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(
                    min(Int(response.expectedContentLength), Self.maximumDownloadBytes)
                )
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumDownloadBytes else {
                    throw WebPageError.pageTooLarge
                }
                data.append(byte)
            }
            if validatesConnectedAddresses,
               !redirectGuard.connectedOnlyToPublicEndpoint(timeout: 1) {
                throw WebPageError.unsafeDestination
            }
            guard let html = Self.decodeHTML(
                data,
                textEncodingName: http.textEncodingName
            ) else {
                throw WebPageError.unreadableText
            }
            return try HTMLArticleExtractor.extract(html: html, sourceURL: finalURL)
        } catch let error as WebPageError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebPageError.transport(error)
        }
    }

    static func validatedHTTPSURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw WebPageError.invalidURL
        }
        // 明文链接只作为用户输入兼容形式；实际请求始终先升级为 HTTPS。
        if scheme == "http", components.port == 80 {
            components.port = nil
        }
        components.scheme = "https"
        components.fragment = nil
        guard let url = components.url else {
            throw WebPageError.invalidURL
        }
        guard NetworkDestinationValidator.isPlausiblyPublicHost(host) else {
            throw WebPageError.unsafeDestination
        }
        return url
    }

    private static func validatePublicDestination(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              NetworkDestinationValidator.resolvesOnlyToPublicAddresses(host) else {
            throw WebPageError.unsafeDestination
        }
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
    private struct Candidate {
        let html: String
        let textLength: Int
    }

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

        let longestArticle = longestCandidate(tag: "article", from: cleanedHTML)
        let longestMain = longestCandidate(tag: "main", from: cleanedHTML)
        let preferredArticle: Candidate?
        if let longestArticle,
           let longestMain,
           longestMain.textLength > longestArticle.textLength * 2 {
            preferredArticle = longestMain
        } else {
            preferredArticle = longestArticle
        }
        let candidate = preferredArticle?.html
            ?? longestMain?.html
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

    private static func longestCandidate(tag: String, from html: String) -> Candidate? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\#(tag)\b[^>]*>([\s\S]*?)</\#(tag)\s*>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range)
            .compactMap { match -> Candidate? in
                guard let contentRange = Range(match.range(at: 1), in: html) else {
                    return nil
                }
                let candidateHTML = String(html[contentRange])
                let text = plainText(from: candidateHTML)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty
                    ? nil
                    : Candidate(html: candidateHTML, textLength: text.count)
            }
            .max { $0.textLength < $1.textLength }
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

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let metricsCondition = NSCondition()
    private var metricsAreSafe: Bool?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              NetworkDestinationValidator.isPlausiblyPublicHost(host),
              NetworkDestinationValidator.resolvesOnlyToPublicAddresses(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let networkTransactions = metrics.transactionMetrics.filter {
            $0.resourceFetchType == .networkLoad
        }
        let isSafe = !networkTransactions.isEmpty && networkTransactions.allSatisfy {
            guard !$0.isProxyConnection,
                  let address = $0.remoteAddress else {
                return false
            }
            return NetworkDestinationValidator.isSafeConnectedAddress(address)
        }

        metricsCondition.lock()
        metricsAreSafe = isSafe
        metricsCondition.broadcast()
        metricsCondition.unlock()
    }

    func connectedOnlyToPublicEndpoint(timeout: TimeInterval) -> Bool {
        metricsCondition.lock()
        defer { metricsCondition.unlock() }
        if metricsAreSafe == nil {
            _ = metricsCondition.wait(until: Date().addingTimeInterval(timeout))
        }
        return metricsAreSafe == true
    }
}

private enum NetworkDestinationValidator {
    static func isSafeConnectedAddress(_ rawAddress: String) -> Bool {
        let address = normalizedHost(rawAddress)
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1,
           isBenchmarkProxyIPv4(UInt32(bigEndian: ipv4.s_addr)) {
            return true
        }
        return isPlausiblyPublicHost(address)
    }

    static func isPlausiblyPublicHost(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)
        guard !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              host != "home.arpa",
              !host.hasSuffix(".home.arpa") else {
            return false
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            // 198.18/15 常被本机透明代理用作 fake-IP，但不允许用户直接访问。
            return !isBenchmarkProxyIPv4(address) && isPublicIPv4(address)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return isPublicIPv6(ipv6)
        }
        return true
    }

    static func resolvesOnlyToPublicAddresses(_ host: String) -> Bool {
        guard isPlausiblyPublicHost(host) else { return false }
        let resolvedHost = normalizedHost(host)

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = resolvedHost.withCString {
            getaddrinfo($0, nil, &hints, &result)
        }
        guard status == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(first) }

        var sawAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            if let address = current.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    sawAddress = true
                    let value = UnsafeRawPointer(address)
                        .assumingMemoryBound(to: sockaddr_in.self)
                        .pointee
                        .sin_addr
                        .s_addr
                    if !isPublicIPv4(UInt32(bigEndian: value)) {
                        return false
                    }
                case AF_INET6:
                    sawAddress = true
                    let value = UnsafeRawPointer(address)
                        .assumingMemoryBound(to: sockaddr_in6.self)
                        .pointee
                        .sin6_addr
                    if !isPublicIPv6(value) {
                        return false
                    }
                default:
                    break
                }
            }
            cursor = current.pointee.ai_next
        }
        return sawAddress
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if let zoneIndex = host.firstIndex(of: "%") {
            host = String(host[..<zoneIndex])
        }
        return host
    }

    private static func isPublicIPv4(_ address: UInt32) -> Bool {
        let first = UInt8((address >> 24) & 0xff)
        let second = UInt8((address >> 16) & 0xff)
        let third = UInt8((address >> 8) & 0xff)

        if first == 0 || first == 10 || first == 127 || first >= 224 {
            return false
        }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 192, second == 0, third == 0 || third == 2 { return false }
        if first == 198, second == 51, third == 100 { return false }
        if first == 203, second == 0, third == 113 { return false }
        return true
    }

    private static func isBenchmarkProxyIPv4(_ address: UInt32) -> Bool {
        let first = UInt8((address >> 24) & 0xff)
        let second = UInt8((address >> 16) & 0xff)
        return first == 198 && (second == 18 || second == 19)
    }

    private static func isPublicIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }

        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0xc0 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false
        }

        let isIPv4Mapped = bytes[0..<10].allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        let isIPv4Compatible = bytes[0..<12].allSatisfy({ $0 == 0 })
        if isIPv4Mapped || isIPv4Compatible {
            let ipv4 = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isPublicIPv4(ipv4)
        }
        return true
    }
}
