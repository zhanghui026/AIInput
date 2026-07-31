import Foundation

enum TransformMode: String, CaseIterable, Sendable {
    case zhToEnglish
    case englishToChinese
    case polish
    case webPage

    var displayName: String {
        switch self {
        case .zhToEnglish: return "中译英"
        case .englishToChinese: return "英译中"
        case .polish: return "润色"
        case .webPage: return "网页翻译"
        }
    }
}

enum WritingTone: String, CaseIterable, Sendable {
    case faithful
    case concise
    case professional
    case natural
    case friendly
    case formal
    case conversational
    case direct
    case confident
    case academic
    case objective

    var displayName: String {
        switch self {
        case .faithful: return "忠实"
        case .concise: return "简洁"
        case .professional: return "专业"
        case .natural: return "自然（去 AI 味）"
        case .friendly: return "友好"
        case .formal: return "正式"
        case .conversational: return "口语"
        case .direct: return "直接"
        case .confident: return "自信 / 说服"
        case .academic: return "学术"
        case .objective: return "客观（去人称）"
        }
    }
}

struct TransformationRequest: Equatable, Sendable {
    let mode: TransformMode
    let tone: WritingTone
    let text: String
    let includeSummary: Bool

    init(mode: TransformMode,
         tone: WritingTone,
         text: String,
         includeSummary: Bool = false) {
        self.mode = mode
        self.tone = tone
        self.text = text
        self.includeSummary = includeSummary
    }
}

enum LanguageDirectionDetector {
    static func suggestedMode(for text: String) -> TransformMode? {
        var hanCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            if isHan(scalar.value) {
                hanCount += 1
            } else if isLatin(scalar.value) {
                latinCount += 1
            }
        }

        guard hanCount > 0 || latinCount > 0, hanCount != latinCount else {
            return nil
        }
        return hanCount > latinCount ? .zhToEnglish : .englishToChinese
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2EBEF).contains(value)
    }

    private static func isLatin(_ value: UInt32) -> Bool {
        (0x0041...0x005A).contains(value)
            || (0x0061...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
    }
}
