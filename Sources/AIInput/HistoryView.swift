import SwiftUI

/// ⌘Y 历史：最近用过的结果，最新在上。↑↓ 选择，⏎ 载入，⌘⏎ 直接粘贴。
struct HistoryView: View {
    static let rowHeight: CGFloat = 54
    static let maxHeight: CGFloat = 330

    @ObservedObject var history: HistoryStore
    let selectedIndex: Int
    let select: (Int) -> Void
    let load: (Int) -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        if history.entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("还没有历史记录")
                    .font(Typography.ui(13, weight: .semibold))
                Text("粘贴、替换或复制过的结果会出现在这里，只保存在本机。")
                    .font(Typography.ui(12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, isSelected: index == selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { load(index) }
                                .onTapGesture { select(index) }
                        }
                    }
                }
                .frame(height: min(CGFloat(history.entries.count) * (Self.rowHeight + 2), Self.maxHeight))
                .onChange(of: selectedIndex) { index in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index) }
                }
            }
        }
    }

    private func row(_ entry: HistoryEntry, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.result)
                .font(Font(Typography.result(size: 15)))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(entry.source)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(meta(for: entry))
                    .font(Typography.ui(11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func meta(for entry: HistoryEntry) -> String {
        var parts = [entry.mode == .polish ? "润色" : entry.tone.chipName]
        if let app = entry.appName { parts.append(app) }
        parts.append(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }
}
