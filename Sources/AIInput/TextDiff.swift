import Foundation

/// 润色前后的逐词对比，用来在结果里标出修订痕迹。
/// 拉丁文字按词、中日韩文字按字切分，空白单独成段，避免整句被标成改动。
enum TextDiff {
    enum Segment: Equatable {
        case same(String)
        case inserted(String)
        case removed(String)
    }

    enum Side {
        case old
        case new
    }

    static func segments(from old: String, to new: String) -> [Segment] {
        let oldTokens = tokens(old)
        let newTokens = tokens(new)
        let difference = newTokens.difference(from: oldTokens)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [Segment] = []
        var i = 0
        var j = 0
        while i < oldTokens.count || j < newTokens.count {
            if i < oldTokens.count, removed.contains(i) {
                append(.removed(oldTokens[i]), to: &result)
                i += 1
            } else if j < newTokens.count, inserted.contains(j) {
                append(.inserted(newTokens[j]), to: &result)
                j += 1
            } else {
                append(.same(newTokens[j]), to: &result)
                i += 1
                j += 1
            }
        }
        return result
    }

    /// 修改处数量：相邻的删除和插入算一处。
    static func changeCount(_ segments: [Segment]) -> Int {
        var count = 0
        var inChange = false
        for segment in segments {
            if case .same = segment {
                inChange = false
            } else if !inChange {
                count += 1
                inChange = true
            }
        }
        return count
    }

    /// 还原某一侧的完整文字（测试和校验用）。
    static func text(of segments: [Segment], including side: Side) -> String {
        segments.map { segment -> String in
            switch (segment, side) {
            case (.same(let text), _): return text
            case (.removed(let text), .old): return text
            case (.inserted(let text), .new): return text
            default: return ""
            }
        }.joined()
    }

    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: Kind?
        for character in text {
            let kind = Kind(character)
            if kind == .ideograph || kind == .punctuation || kind != currentKind {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
            current.append(character)
            currentKind = kind
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private enum Kind {
        case word
        case space
        case ideograph
        case punctuation

        init(_ character: Character) {
            if character.isWhitespace {
                self = .space
            } else if character.unicodeScalars.contains(where: Self.isIdeographic) {
                self = .ideograph
            } else if character.isLetter || character.isNumber || character == "'" || character == "’" {
                self = .word
            } else {
                self = .punctuation
            }
        }

        private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func append(_ segment: Segment, to segments: inout [Segment]) {
        switch (segments.last, segment) {
        case (.same(let a)?, .same(let b)):
            segments[segments.count - 1] = .same(a + b)
        case (.inserted(let a)?, .inserted(let b)):
            segments[segments.count - 1] = .inserted(a + b)
        case (.removed(let a)?, .removed(let b)):
            segments[segments.count - 1] = .removed(a + b)
        default:
            segments.append(segment)
        }
    }
}
