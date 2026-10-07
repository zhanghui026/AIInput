import SwiftUI

/// 自动换行的横向排布，用来放 chip。
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}

/// 卡片里的小胶囊。有 `action` 时可以点，点了会打开这一项自己的卡片。
struct CardChip: View {
    let title: String
    var detail: String?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .help("查看「\(title)」的卡片")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(title)
            if let detail, !detail.isEmpty {
                Text("（\(detail)）")
                    .foregroundColor(.secondary)
            }
        }
        .font(Typography.ui(12.5))
        .foregroundColor(action == nil ? .primary : .accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(action == nil ? 0.04 : 0.09)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(action == nil ? 0.12 : 0.3), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// 词/句的大标题：词本身、音标、词性、等级。
struct CardHeadline: View {
    let text: String
    let kind: CardKind
    let head: CardHead?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text)
                    .font(Font(Typography.result(size: kind == .word ? 30 : 21)))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if kind == .word {
                    if let ipa = head?.ipa, !ipa.isEmpty {
                        Text(ipa)
                            .font(Typography.ui(14))
                            .foregroundColor(.secondary)
                            .help("音标由 AI 标注，仅供参考；点喇叭听系统朗读")
                    }
                    if let pos = head?.pos, !pos.isEmpty {
                        Text(pos)
                            .font(Font(Typography.result(size: 14)).italic())
                            .foregroundColor(.secondary)
                    }
                    if let level = head?.level, !level.isEmpty {
                        Text(level)
                            .font(Typography.ui(11, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1.5)
                            .overlay(Capsule().stroke(Color.accentColor.opacity(0.5), lineWidth: 0.5))
                            .help("CEFR 等级由 AI 标注，仅供参考")
                    }
                } else if let label = head?.label, !label.isEmpty {
                    Text(label)
                        .font(Typography.ui(11.5))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
                }
            }
            if kind == .word, let lemma = head?.lemma, !lemma.isEmpty,
               SelectionClassifier.normalized(lemma) != SelectionClassifier.normalized(text) {
                Text("原形 \(lemma)")
                    .font(Typography.ui(12))
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 卡片的各个区块。面板里的卡片和生词本里的详情共用。
struct CardBlocksView: View {
    let blocks: [CardBlock]
    /// 点 chip 时调用；nil 表示 chip 不可点。
    var onChip: ((String) -> Void)?

    private static let circled = ["①", "②", "③", "④", "⑤", "⑥"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: CardBlock) -> some View {
        switch block {
        case .head, .unknown:
            EmptyView()
        case .senses(let value):
            section("义项") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(value.items.enumerated()), id: \.offset) { index, sense in
                        senseRow(sense, index: index)
                    }
                }
            }
        case .teacher(let value):
            VStack(alignment: .leading, spacing: 5) {
                title("老师怎么讲 · Teacher")
                Text(value.en)
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let zh = value.zh, !zh.isEmpty {
                    Text(zh)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.13)))
        case .usage(let value):
            section("什么时候用 · When") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(value.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.scene)
                                .font(Typography.ui(11.5))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            Text(item.en)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        case .alternatives(let value):
            VStack(alignment: .leading, spacing: 10) {
                if let items = value.items, !items.isEmpty {
                    section("换种说法 · Say it another way") {
                        FlowLayout {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, alt in
                                CardChip(title: alt.w, detail: alt.note, action: chipAction(alt.w))
                            }
                        }
                    }
                }
                if let avoid = value.avoid, !avoid.isEmpty {
                    section("别用错") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(avoid.enumerated()), id: \.offset) { _, alt in
                                Text(alt.note.map { "\(alt.w) = \($0)" } ?? alt.w)
                                    .font(.system(size: 13))
                            }
                        }
                    }
                }
            }
        case .sentence(let value):
            section("整句") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.en)
                        .font(Font(Typography.result(size: 15)))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let literal = value.literal, !literal.isEmpty {
                        labeled("直", literal)
                    }
                    if let free = value.free, !free.isEmpty {
                        labeled("意", free)
                    }
                }
            }
        case .family(let value):
            section("词族") {
                chips(value.items)
            }
        case .translation(let value):
            section("翻译") {
                VStack(alignment: .leading, spacing: 3) {
                    if let literal = value.literal, !literal.isEmpty {
                        labeled("直译", literal)
                    }
                    labeled("通顺", value.natural)
                }
            }
        case .pattern(let value):
            section("句型骨架 · Pattern") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.skeleton)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.accentColor)
                        .textSelection(.enabled)
                    if let variants = value.variants, !variants.isEmpty {
                        Text("→ " + variants.joined(separator: " / "))
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    if let drill = value.drill, !drill.isEmpty {
                        labeled("填空示例", drill)
                    }
                }
            }
        case .similar(let value):
            section("同类说法 · Similar") {
                VStack(alignment: .leading, spacing: 6) {
                    chips(value.items)
                    if let note = value.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
        case .idioms(let value):
            section("相关习语") {
                chips(value.items)
            }
        case .note(let value):
            section(value.title ?? "说明") {
                Text(value.text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func senseRow(_ sense: CardSense, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.circled[min(index, Self.circled.count - 1)])
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let tag = sense.tag, !tag.isEmpty {
                        Text("（\(tag)）")
                            .font(.system(size: 13.5))
                            .foregroundColor(.orange)
                    }
                    Text(sense.zh)
                        .font(.system(size: 14, weight: .semibold))
                    if sense.ctx == true {
                        Text("本句")
                            .font(Typography.ui(10.5, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.accentColor.opacity(0.5), lineWidth: 0.5))
                    }
                }
                if let en = sense.en, !en.isEmpty {
                    Text(en)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                if let enzh = sense.enzh, !enzh.isEmpty {
                    Text(enzh)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func chips(_ items: [String]) -> some View {
        FlowLayout {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                CardChip(title: item, action: chipAction(item))
            }
        }
    }

    private func chipAction(_ item: String) -> (() -> Void)? {
        guard let onChip else { return nil }
        return { onChip(item) }
    }

    private func labeled(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(Typography.ui(11.5))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui(12.5, weight: .semibold))
    }

    private func section<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title(name)
            content()
        }
    }
}
