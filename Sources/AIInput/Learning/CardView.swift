import SwiftUI

/// 面板里的学习卡片（⌘I）：顶部工具栏 + 标题 + 可滚动的区块。
struct CardView: View {
    static let minContentHeight: CGFloat = 220
    static var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(max(screen * 0.55, 380), 620)
    }

    @ObservedObject var card: CardModel
    @State private var dictionaryOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let target = card.target {
                CardHeadline(text: target.text, kind: target.kind, head: card.blocks.head)
                lookupLine
                // 生成中先留出舒适的高度，免得一开始缩成一条、边生成边跳。
                CappedScroll(minHeight: card.isLoading ? Self.minContentHeight : 40, maxHeight: Self.maxContentHeight) {
                    blocksContent(of: target)
                        .padding(.trailing, 6)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let previous = card.trail.last {
                Button(action: card.pop) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(previous.text)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                        Keycap("⌘[")
                    }
                    .font(Typography.ui(12))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("回到上一张卡片（⌘[）")
            }
            if let kind = card.target?.kind {
                HStack(spacing: 6) {
                    ForEach(Array(CardKind.allCases.enumerated()), id: \.element) { index, option in
                        kindButton(option, selected: option == kind, index: index)
                    }
                }
            }
            Spacer(minLength: 8)
            speakButton
            saveButton
        }
    }

    private func kindButton(_ option: CardKind, selected: Bool, index: Int) -> some View {
        Button { card.setKind(option) } label: {
            HStack(spacing: 5) {
                Text(option.displayName)
                Text("⌘\(index + 1)")
                    .font(Typography.keycap)
                    .opacity(0.7)
            }
            .font(Typography.ui(12, weight: selected ? .semibold : .regular))
            .foregroundColor(selected ? .accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .help("按\(option.displayName)来讲解")
    }

    private var speakButton: some View {
        Button(action: card.speak) {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                Keycap("⌘P")
            }
            .font(Typography.ui(12))
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: .command)
        .help("朗读（⌘P）")
    }

    private var saveButton: some View {
        let kind = card.target?.kind ?? .word
        return Button(action: card.toggleSaved) {
            HStack(spacing: 5) {
                Image(systemName: card.isSaved ? "bookmark.fill" : "bookmark")
                Text(card.isSaved ? "已收进\(kind.notebookName)" : "收进\(kind.notebookName)")
                Keycap("⌘S")
            }
            .font(Typography.ui(12, weight: card.isSaved ? .semibold : .regular))
            .foregroundColor(card.isSaved ? .accentColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(card.stage != .ready)
        .help(card.isSaved ? "再按一次从\(kind.notebookName)移除" : "收进\(kind.notebookName)，之后可以复习")
    }

    // MARK: - 查词记录

    @ViewBuilder
    private var lookupLine: some View {
        if card.lookupCount >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                Label("你第 \(card.lookupCount) 次查这个\(card.target?.kind == .word ? "词" : "说法")了", systemImage: "arrow.counterclockwise")
                    .font(Typography.ui(12, weight: .semibold))
                    .foregroundColor(.orange)
                ForEach(card.earlierContexts.prefix(2), id: \.self) { context in
                    Text("之前遇到：\(context)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private func blocksContent(of target: CardTarget) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            switch card.stage {
            case .failed(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13.5))
                .foregroundColor(.red)
                CardBlocksView(blocks: card.blocks, onChip: card.push)
            case .idle:
                EmptyView()
            case .loading where card.blocks.isEmpty:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在生成\(target.kind.cardName)…")
                        .font(Typography.ui(13))
                        .foregroundColor(.secondary)
                }
            case .loading, .ready:
                CardBlocksView(blocks: card.blocks, onChip: card.push)
                if card.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            dictionarySection
        }
    }

    @ViewBuilder
    private var dictionarySection: some View {
        if let text = card.dictionaryText {
            if card.isLoading && card.blocks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("词典释义（系统词典）")
                        .font(Typography.ui(12.5, weight: .semibold))
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                // 展开状态放在 CardView 里：可见内容和量高度用的副本要同步展开。
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        dictionaryOpen.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: dictionaryOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 10)
                            Text("词典释义（系统词典）")
                                .font(Typography.ui(12.5, weight: .semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if dictionaryOpen {
                        Text(text)
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// 竖向滚动区：高度等于内容高度，夹在 [minHeight, maxHeight] 之间，内容更高时才滚动。
/// 内容高度由 Layout 同步量出（不可见的副本），不依赖 ScrollView 在 fixedSize 父视图里的理想尺寸，
/// 也不依赖 PreferenceKey 的异步回写。
private struct CappedScroll<Content: View>: View {
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        CappedHeightLayout(minHeight: minHeight, maxHeight: maxHeight) {
            ScrollView { content }
            content
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct CappedHeightLayout: Layout {
    let minHeight: CGFloat
    let maxHeight: CGFloat

    private func height(_ subviews: Subviews, width: CGFloat) -> CGFloat {
        guard subviews.count == 2 else { return minHeight }
        let natural = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return min(max(natural, minHeight), maxHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: height(subviews, width: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        subviews[1].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
