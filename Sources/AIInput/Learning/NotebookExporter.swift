import Foundation

/// 把卡片区块转成纯文本的小节，Markdown 和 Anki 导出共用。
enum CardPlainText {
    struct Section: Equatable {
        let title: String
        let lines: [String]
    }

    static func sections(for blocks: [CardBlock]) -> [Section] {
        var result: [Section] = []
        for block in blocks {
            switch block {
            case .head, .unknown:
                continue
            case .senses(let value):
                let lines = value.items.enumerated().map { index, sense -> String in
                    var line = "\(index + 1). "
                    if let tag = sense.tag, !tag.isEmpty { line += "（\(tag)）" }
                    line += sense.zh
                    if let en = sense.en, !en.isEmpty { line += " — \(en)" }
                    if let enzh = sense.enzh, !enzh.isEmpty { line += " \(enzh)" }
                    return line
                }
                result.append(Section(title: "义项", lines: lines))
            case .teacher(let value):
                result.append(Section(title: "老师怎么讲", lines: [value.en] + (value.zh.map { [$0] } ?? [])))
            case .usage(let value):
                result.append(Section(title: "什么时候用", lines: value.items.map { "\($0.scene)：\($0.en)" }))
            case .alternatives(let value):
                if let items = value.items, !items.isEmpty {
                    result.append(Section(title: "换种说法", lines: items.map { alt in alt.note.map { "\(alt.w)（\($0)）" } ?? alt.w }))
                }
                if let avoid = value.avoid, !avoid.isEmpty {
                    result.append(Section(title: "别用错", lines: avoid.map { alt in alt.note.map { "\(alt.w) = \($0)" } ?? alt.w }))
                }
            case .sentence(let value):
                result.append(Section(title: "整句", lines: [value.en]
                    + (value.literal.map { ["直：\($0)"] } ?? [])
                    + (value.free.map { ["意：\($0)"] } ?? [])))
            case .family(let value):
                result.append(Section(title: "词族", lines: [value.items.joined(separator: " · ")]))
            case .translation(let value):
                result.append(Section(title: "翻译", lines: (value.literal.map { ["直译：\($0)"] } ?? []) + ["通顺：\(value.natural)"]))
            case .pattern(let value):
                var lines = [value.skeleton]
                if let variants = value.variants, !variants.isEmpty { lines.append("→ " + variants.joined(separator: " / ")) }
                if let drill = value.drill, !drill.isEmpty { lines.append("填空：\(drill)") }
                result.append(Section(title: "句型骨架", lines: lines))
            case .similar(let value):
                result.append(Section(title: "同类说法", lines: [value.items.joined(separator: " · ")] + (value.note.map { [$0] } ?? [])))
            case .idioms(let value):
                result.append(Section(title: "相关习语", lines: [value.items.joined(separator: " · ")]))
            case .note(let value):
                result.append(Section(title: value.title ?? "说明", lines: [value.text]))
            }
        }
        return result.filter { !$0.lines.isEmpty }
    }
}

enum NotebookExporter {
    /// Markdown：按收藏日期分组，适合直接放进 Obsidian。
    static func markdown(_ entries: [NotebookEntry], calendar: Calendar = .current) -> String {
        guard !entries.isEmpty else { return "# AIInput 生词本与句型本\n\n（还没有内容）\n" }
        var output = "# AIInput 生词本与句型本\n"
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var lastDay: String?
        for entry in entries.sorted(by: { $0.createdAt > $1.createdAt }) {
            let day = formatter.string(from: entry.createdAt)
            if day != lastDay {
                output += "\n## \(day)\n"
                lastDay = day
            }
            let heading = entry.surface.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            output += "\n### \(heading)"
            if let head = entry.blocks.head {
                let meta = [head.ipa, head.pos, head.level].compactMap { $0 }.filter { !$0.isEmpty }
                if !meta.isEmpty { output += "  `\(meta.joined(separator: " · "))`" }
            }
            output += "\n\n#\(entry.kind == .word ? "生词" : "句型")"
            if let app = entry.appName { output += " · 来自 \(app)" }
            output += "\n"
            if let context = entry.context, !context.isEmpty {
                output += "\n> \(context)\n"
            }
            for section in CardPlainText.sections(for: entry.blocks) {
                output += "\n**\(section.title)**\n"
                for line in section.lines { output += "- \(line)\n" }
            }
        }
        return output
    }

    /// Anki 导入用的 TSV（制表符分隔，允许 HTML）：正面是原文，背面是释义和整张卡片。
    static func ankiTSV(_ entries: [NotebookEntry]) -> String {
        var output = "#separator:tab\n#html:true\n#columns:Front\tBack\tTags\n#tags column:3\n"
        for entry in entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            var back = ""
            if !entry.gloss.isEmpty { back += "<b>\(escape(entry.gloss))</b>" }
            if let context = entry.context, !context.isEmpty {
                back += "<br><i>\(escape(context))</i>"
            }
            for section in CardPlainText.sections(for: entry.blocks) {
                back += "<br><br><u>\(escape(section.title))</u>"
                for line in section.lines { back += "<br>\(escape(line))" }
            }
            let tag = entry.kind == .word ? "AIInput::word" : "AIInput::pattern"
            output += "\(field(escape(entry.surface)))\t\(field(back))\t\(tag)\n"
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
