import Foundation

// 模型按行输出的卡片区块（NDJSON）。字段名就是协议，同一套 Codable 也用来存生词本，
// 所以改字段名要连同 schemaVersion 一起考虑。除 `type` 外尽量都是可选的：
// 少一个字段不应该让整块丢掉。

struct CardHead: Codable, Equatable, Sendable {
    var lemma: String?
    var ipa: String?
    var pos: String?
    var level: String?
    /// 词组/句子的类型标签，例如「短语 / Phrase」。
    var label: String?
}

struct CardSense: Codable, Equatable, Sendable {
    var zh: String
    var pos: String?
    /// 感情色彩或语体：贬、褒、口语、正式……
    var tag: String?
    var en: String?
    var enzh: String?
    /// 在带进来的整句里用的是这一义。
    var ctx: Bool?
}

struct CardSenses: Codable, Equatable, Sendable {
    var items: [CardSense]
}

struct CardTeacher: Codable, Equatable, Sendable {
    var en: String
    var zh: String?
}

struct CardUsage: Codable, Equatable, Sendable {
    var scene: String
    var en: String
}

struct CardUsageList: Codable, Equatable, Sendable {
    var items: [CardUsage]
}

struct CardAlt: Codable, Equatable, Sendable {
    var w: String
    var note: String?
}

struct CardAlternatives: Codable, Equatable, Sendable {
    var items: [CardAlt]?
    var avoid: [CardAlt]?
}

struct CardSentence: Codable, Equatable, Sendable {
    var en: String
    var literal: String?
    var free: String?
}

struct CardChips: Codable, Equatable, Sendable {
    var items: [String]
}

struct CardTranslation: Codable, Equatable, Sendable {
    var literal: String?
    var natural: String
}

struct CardPattern: Codable, Equatable, Sendable {
    var skeleton: String
    var variants: [String]?
    var drill: String?
}

struct CardSimilar: Codable, Equatable, Sendable {
    var items: [String]
    var note: String?
}

struct CardNote: Codable, Equatable, Sendable {
    var title: String?
    var text: String
}

enum CardBlock: Equatable, Sendable {
    case head(CardHead)
    case senses(CardSenses)
    case teacher(CardTeacher)
    case usage(CardUsageList)
    case alternatives(CardAlternatives)
    case sentence(CardSentence)
    case family(CardChips)
    case translation(CardTranslation)
    case pattern(CardPattern)
    case similar(CardSimilar)
    case idioms(CardChips)
    case note(CardNote)
    /// 认不出的区块类型（比如以后版本新增的），保留类型名但不显示。
    case unknown(String)

    var isEmpty: Bool {
        switch self {
        case .head(let v): return [v.lemma, v.ipa, v.pos, v.level, v.label].allSatisfy { ($0 ?? "").isEmpty }
        case .senses(let v): return v.items.isEmpty
        case .teacher(let v): return v.en.isEmpty
        case .usage(let v): return v.items.isEmpty
        case .alternatives(let v): return (v.items ?? []).isEmpty && (v.avoid ?? []).isEmpty
        case .sentence(let v): return v.en.isEmpty
        case .family(let v), .idioms(let v): return v.items.isEmpty
        case .translation(let v): return v.natural.isEmpty
        case .pattern(let v): return v.skeleton.isEmpty
        case .similar(let v): return v.items.isEmpty
        case .note(let v): return v.text.isEmpty
        case .unknown: return true
        }
    }
}

extension CardBlock: Codable {
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "head": self = .head(try CardHead(from: decoder))
        case "senses": self = .senses(try CardSenses(from: decoder))
        case "teacher": self = .teacher(try CardTeacher(from: decoder))
        case "usage": self = .usage(try CardUsageList(from: decoder))
        case "alt": self = .alternatives(try CardAlternatives(from: decoder))
        case "sentence": self = .sentence(try CardSentence(from: decoder))
        case "family": self = .family(try CardChips(from: decoder))
        case "trans": self = .translation(try CardTranslation(from: decoder))
        case "pattern": self = .pattern(try CardPattern(from: decoder))
        case "similar": self = .similar(try CardSimilar(from: decoder))
        case "idioms": self = .idioms(try CardChips(from: decoder))
        case "note": self = .note(try CardNote(from: decoder))
        default: self = .unknown(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        let tag: String
        switch self {
        case .head(let v): try v.encode(to: encoder); tag = "head"
        case .senses(let v): try v.encode(to: encoder); tag = "senses"
        case .teacher(let v): try v.encode(to: encoder); tag = "teacher"
        case .usage(let v): try v.encode(to: encoder); tag = "usage"
        case .alternatives(let v): try v.encode(to: encoder); tag = "alt"
        case .sentence(let v): try v.encode(to: encoder); tag = "sentence"
        case .family(let v): try v.encode(to: encoder); tag = "family"
        case .translation(let v): try v.encode(to: encoder); tag = "trans"
        case .pattern(let v): try v.encode(to: encoder); tag = "pattern"
        case .similar(let v): try v.encode(to: encoder); tag = "similar"
        case .idioms(let v): try v.encode(to: encoder); tag = "idioms"
        case .note(let v): try v.encode(to: encoder); tag = "note"
        case .unknown(let type): tag = type
        }
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(tag, forKey: .type)
    }
}

/// 解码数组时跳过坏掉的元素，而不是整个文件读不出来。
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Array where Element == CardBlock {
    /// 方便读取：卡片里第一处中文释义，用作复习提示。
    var firstGloss: String? {
        for block in self {
            switch block {
            case .senses(let senses):
                if let sense = senses.items.first(where: { $0.ctx == true }) ?? senses.items.first {
                    return sense.zh
                }
            case .translation(let value):
                return value.natural
            default:
                continue
            }
        }
        return nil
    }

    var firstPattern: CardPattern? {
        for case .pattern(let pattern) in self { return pattern }
        return nil
    }

    var head: CardHead? {
        for case .head(let head) in self { return head }
        return nil
    }
}
