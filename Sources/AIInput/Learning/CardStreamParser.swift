import Foundation

/// 从模型流式输出的累计文本里，逐个取出完整的 JSON 对象（卡片区块）。
///
/// 不按换行切：模型会把一个对象拆成多行、把两个对象写在一行、在前面加一句废话或
/// 代码围栏。这里按花括号深度扫描（识别字符串和转义），只处理新增的字节，
/// 末尾被截断的对象留到下一次，直到流结束仍不完整就丢弃。
final class CardStreamParser {
    private var scanned = 0
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var current: [UInt8] = []
    private var thinkResolved = false

    private static let openThink = "<think>"
    private static let closeThink = "</think>"

    /// 传入截至目前的完整文本，返回这次新完成的区块。
    func update(with text: String) -> [CardBlock] {
        if !thinkResolved {
            guard skipThinking(in: text) else { return [] }
        }
        var blocks: [CardBlock] = []
        for byte in text.utf8.dropFirst(scanned) {
            scanned += 1
            if depth == 0 {
                if byte == UInt8(ascii: "{") {
                    depth = 1
                    current = [byte]
                }
                continue
            }
            current.append(byte)
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    if let block = Self.decode(current) {
                        blocks.append(block)
                    }
                    current = []
                }
            default:
                break
            }
        }
        return blocks
    }

    /// 推理模型有时把思考过程内联在正文开头：跳过它，里面的花括号不是卡片。
    /// 返回 false 表示思考还没结束，先不扫描。
    private func skipThinking(in text: String) -> Bool {
        let head = text.drop(while: { $0.isWhitespace })
        if head.hasPrefix(Self.openThink) {
            guard let end = text.range(of: Self.closeThink) else { return false }
            scanned = text.utf8.distance(from: text.startIndex, to: end.upperBound)
        } else if head.isEmpty || Self.openThink.hasPrefix(String(head)) {
            // 还不足以判断开头是不是 <think>。
            return false
        }
        thinkResolved = true
        return true
    }

    private static func decode(_ bytes: [UInt8]) -> CardBlock? {
        guard let block = try? JSONDecoder().decode(CardBlock.self, from: Data(bytes)),
              !block.isEmpty else {
            return nil
        }
        return block
    }
}
