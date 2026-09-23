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

/// 面板上可选的任务。翻译的具体方向由 `TranslationDirection` 决定。
enum PanelMode: String, CaseIterable, Sendable {
    case translate
    case polish
    case webPage

    var displayName: String {
        switch self {
        case .translate: return "翻译"
        case .polish: return "润色"
        case .webPage: return "网页"
        }
    }
}

enum TranslationDirection: String, CaseIterable, Sendable {
    case auto
    case zhToEnglish
    case englishToChinese

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .zhToEnglish: return "中→英"
        case .englishToChinese: return "英→中"
        }
    }
}

/// 把面板选项和输入内容解析成实际执行的任务。
enum ModeResolver {
    static func resolve(panelMode: PanelMode,
                        direction: TranslationDirection,
                        text: String) -> TransformMode {
        if panelMode == .webPage || isSingleURL(text) {
            return .webPage
        }
        switch panelMode {
        case .polish:
            return .polish
        case .translate, .webPage:
            switch direction {
            case .zhToEnglish: return .zhToEnglish
            case .englishToChinese: return .englishToChinese
            case .auto: return LanguageDirectionDetector.resolvedMode(for: text)
            }
        }
    }

    /// 整段输入恰好是一个 http(s) 链接。
    static func isSingleURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
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
    /// 总能给出方向：明显占优时用 `suggestedMode`，否则含汉字按中译英处理
    /// （中文里夹英文术语是最常见的混排），纯拉丁/无文字按英译中。
    static func resolvedMode(for text: String) -> TransformMode {
        if let mode = suggestedMode(for: text) {
            return mode
        }
        return text.unicodeScalars.contains { isHan($0.value) } ? .zhToEnglish : .englishToChinese
    }

    static func suggestedMode(for text: String) -> TransformMode? {
        var hanCount = 0
        let textWithoutURLs = text.replacingOccurrences(
            of: #"https?://\S+"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        for scalar in textWithoutURLs.unicodeScalars {
            if isHan(scalar.value) {
                hanCount += 1
            }
        }

        let latinWordCount: Int
        if let regex = try? NSRegularExpression(pattern: #"\p{Latin}+"#) {
            latinWordCount = regex.numberOfMatches(
                in: textWithoutURLs,
                range: NSRange(textWithoutURLs.startIndex..., in: textWithoutURLs)
            )
        } else {
            latinWordCount = 0
        }

        if hanCount == 0 {
            return latinWordCount > 0 ? .englishToChinese : nil
        }
        if latinWordCount == 0 {
            return .zhToEnglish
        }

        // 混排文本只有一方明显占优时才自动提交，避免把技术术语、URL、
        // 人名等拉丁字符误判成整段英文。
        if hanCount >= latinWordCount * 4 {
            return .zhToEnglish
        }
        if latinWordCount >= hanCount * 4 {
            return .englishToChinese
        }
        return nil
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2EBEF).contains(value)
    }
}
