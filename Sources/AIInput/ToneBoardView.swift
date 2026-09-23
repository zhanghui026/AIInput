import SwiftUI

/// 多语气视图：顶部分组标签，下面 2×2 卡片同时流式出结果。
struct ToneBoardView: View {
    @ObservedObject var board: ToneBoard

    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabs
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(board.tones.enumerated()), id: \.element) { index, tone in
                    ToneCard(
                        tone: tone,
                        shortcut: "⌘\(index + 1)",
                        card: board.cards[tone],
                        isChosen: board.chosen == tone,
                        choose: { board.choose(tone) },
                        retry: { board.retry(tone) }
                    )
                }
            }
        }
        .background(shortcuts)
    }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach(ToneGroup.allCases, id: \.self) { group in
                let isSelected = group == board.group
                Button {
                    board.selectGroup(group)
                } label: {
                    VStack(spacing: 5) {
                        Text(group.displayName)
                            .font(Typography.ui(13, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .primary : .secondary)
                        Rectangle()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Keycap("⌘← ⌘→")
                .padding(.bottom, 6)
            Spacer()
        }
    }

    /// 不可见的按钮，只为提供 ⌘1–4 选卡片、⌘←/⌘→ 切分组的快捷键。
    private var shortcuts: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Button("") { board.choose(index: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { board.moveGroup(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("") { board.moveGroup(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct ToneCard: View {
    let tone: WritingTone
    let shortcut: String
    let card: ToneBoard.Card?
    let isChosen: Bool
    let choose: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tone.chipName)
                    .font(Typography.ui(12, weight: isChosen ? .semibold : .regular))
                    .foregroundColor(isChosen ? .accentColor : .secondary)
                Spacer()
                Keycap(shortcut)
            }
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
                isChosen ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.1),
                lineWidth: isChosen ? 1.5 : 0.5
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .running(let partial) where !partial.isEmpty:
            resultText(partial + " ▍")
        case .running, .none:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("生成中…")
                    .font(Typography.ui(12))
                    .foregroundColor(.secondary)
            }
            .frame(height: 22)
        case .done(let text):
            resultText(text)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(3)
                Button("重试", action: retry)
                    .font(Typography.ui(12))
            }
        }
    }

    private func resultText(_ text: String) -> some View {
        Text(text)
            .font(Font(Typography.result(size: 15)))
            .lineSpacing(2)
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
