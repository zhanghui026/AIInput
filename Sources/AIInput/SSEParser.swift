import Foundation

enum SSEEvent: Equatable {
    case text(String)
    case stop
}

/// 解析 Anthropic Messages 流式响应（SSE）的单行。只关心 `data:` 行：
/// 文本增量、结束、截断和服务端错误；thinking 增量、ping 等一律忽略。
enum SSEParser {
    static func parse(line: String) throws -> SSEEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else {
                return nil
            }
            return .text(text)
        case "message_delta":
            let delta = json["delta"] as? [String: Any]
            if delta?["stop_reason"] as? String == "max_tokens" {
                throw TranslationService.TranslationError.outputTruncated
            }
            return nil
        case "message_stop":
            return .stop
        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? ""
            throw TranslationService.TranslationError.badStatus(
                statusCode(forErrorType: error?["type"] as? String),
                message,
                retryAfter: nil
            )
        default:
            return nil
        }
    }

    private static func statusCode(forErrorType type: String?) -> Int {
        switch type {
        case "overloaded_error": return 529
        case "rate_limit_error": return 429
        case "authentication_error": return 401
        case "permission_error": return 403
        case "invalid_request_error": return 400
        default: return 500
        }
    }
}
