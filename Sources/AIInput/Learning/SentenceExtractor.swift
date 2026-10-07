import Foundation
import NaturalLanguage

/// 从输入框的全文里取出选中文字所在的那一整句，给词卡当上下文。
enum SentenceExtractor {
    /// 超过这个长度的全文（整篇文档）不处理，避免卡住主线程。
    static let maxFullTextLength = 50_000
    static let maxSentenceLength = 400
    /// 只在选区前后这么多字符里断句。
    private static let window = 1_500

    /// `selectedRange` 来自辅助功能，可能和 `selected` 对不上（不同 App 的偏移单位不一致），
    /// 对不上时改为在全文里找 `selected` 第一次出现的位置。
    static func sentence(in full: String, selectedRange: NSRange?, selected: String) -> String? {
        let text = full as NSString
        let selected = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.length > 0, text.length <= maxFullTextLength, !selected.isEmpty else { return nil }

        var range = NSRange(location: NSNotFound, length: 0)
        if let candidate = selectedRange,
           candidate.location >= 0, candidate.length > 0, NSMaxRange(candidate) <= text.length,
           text.substring(with: candidate).trimmingCharacters(in: .whitespacesAndNewlines) == selected {
            range = candidate
        } else {
            range = text.range(of: selected)
        }
        guard range.location != NSNotFound else { return nil }

        let lower = max(0, range.location - window)
        let upper = min(text.length, NSMaxRange(range) + window)
        // 硬换行的文本里，单个换行只是折行，不是句子边界；替换成同长度的空格，偏移不变。
        let slice = text.substring(with: NSRange(location: lower, length: upper - lower))
            .replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: " ", options: .regularExpression)
        let relative = NSRange(location: range.location - lower, length: range.length)

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = slice
        tokenizer.setLanguage(.english)
        var found: String?
        tokenizer.enumerateTokens(in: slice.startIndex..<slice.endIndex) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: slice)
            guard nsRange.location <= relative.location, relative.location < NSMaxRange(nsRange) else {
                return true
            }
            // 选区跨句时不给上下文：它不是「某句里的一个词」。
            if NSMaxRange(relative) <= NSMaxRange(nsRange) {
                found = String(slice[tokenRange])
            }
            return false
        }

        guard let sentence = found.map(collapse), !sentence.isEmpty,
              sentence.count <= maxSentenceLength,
              sentence.rangeOfCharacter(from: .letters) != nil,
              SelectionClassifier.normalized(sentence) != SelectionClassifier.normalized(selected) else {
            return nil
        }
        return sentence
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
