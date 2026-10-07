import Foundation
import NaturalLanguage

/// 学习卡片的类型：单词用词卡，词组和句子用句卡。
enum CardKind: String, Codable, CaseIterable, Sendable {
    case word
    case phrase
    case sentence

    var displayName: String {
        switch self {
        case .word: return "词"
        case .phrase: return "词组"
        case .sentence: return "句子"
        }
    }

    var cardName: String {
        switch self {
        case .word: return "词卡"
        case .phrase: return "词组卡"
        case .sentence: return "句卡"
        }
    }

    /// 收进哪一本：单词进生词本，词组和句子进句型本。
    var notebookName: String {
        self == .word ? "生词本" : "句型本"
    }
}

/// 一张卡片要讲的对象。`context` 是它在原文里所在的整句（取不到时为 nil）。
struct CardTarget: Equatable, Codable, Sendable {
    var text: String
    var kind: CardKind
    var context: String?
}

/// 判断选中的英文是单词、词组还是句子。
enum SelectionClassifier {
    /// 超过这个长度就不再当作学习对象（那是一整段文字）。
    static let maxWords = 80
    static let maxCharacters = 600
    /// 不带句末标点时，最多这么多个词仍算词组。
    static let maxPhraseWords = 8

    private static let trimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"“”‘’'.,;:!?()[]{}<>«»…—–-"))

    /// 不是英文、太长或没有字母时返回 nil（此时不提供卡片）。
    static func kind(for text: String) -> CardKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxCharacters,
              trimmed.rangeOfCharacter(from: .letters) != nil,
              LanguageDirectionDetector.resolvedMode(for: trimmed) == .englishToChinese,
              !trimmed.contains("://") else {
            return nil
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= maxWords else { return nil }
        if words.count == 1 { return .word }
        if endsSentence(trimmed) || words.count > maxPhraseWords { return .sentence }
        return .phrase
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…。？！".contains(last)
    }

    /// 小写、去掉首尾标点、空白折叠成一个空格。
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: trimSet)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// 查词记录和生词本共用的键：单词按原形（rushed 和 rush 是同一个），其余按规范化原文。
enum LookupKey {
    static func make(kind: CardKind, text: String) -> String {
        let normalized = SelectionClassifier.normalized(text)
        switch kind {
        case .word:
            return "w:" + lemma(of: normalized)
        case .phrase, .sentence:
            return "p:" + normalized
        }
    }

    /// 系统词形还原；专有名词或不认识的词返回 nil 时退回小写原词。
    static func lemma(of word: String) -> String {
        guard !word.isEmpty else { return word }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex..<word.endIndex)
        let tag = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0
        let lemma = tag?.rawValue.lowercased() ?? word
        return lemma.isEmpty ? word : lemma
    }
}
