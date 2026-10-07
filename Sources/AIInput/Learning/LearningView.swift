import AppKit
import SwiftUI

/// 学习窗口：复习、生词本/句型本、统计。
struct LearningView: View {
    enum Tab: String, CaseIterable {
        case review = "复习"
        case notebook = "本子"
        case stats = "统计"
    }

    @ObservedObject var notebook: NotebookStore
    @ObservedObject var lookups: LookupLog
    @ObservedObject var session: ReviewSession
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab == .review && notebook.dueCount() > 0 ? "复习（\(notebook.dueCount())）" : tab.rawValue)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            switch tab {
            case .review:
                ReviewTab(notebook: notebook, session: session)
            case .notebook:
                NotebookTab(notebook: notebook)
            case .stats:
                StatsTab(notebook: notebook, lookups: lookups)
            }
        }
        .frame(minWidth: 780, minHeight: 600)
    }
}

// MARK: - 复习

private struct ReviewTab: View {
    @ObservedObject var notebook: NotebookStore
    @ObservedObject var session: ReviewSession
    @State private var showsCard = false

    var body: some View {
        Group {
            if !session.started {
                lobby
            } else if let entry = session.current, let question = session.question {
                questionView(entry: entry, question: question)
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lobby: some View {
        let due = notebook.dueCount()
        return VStack(spacing: 14) {
            Image(systemName: due > 0 ? "rectangle.stack.badge.play" : "checkmark.seal")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            if notebook.entries.isEmpty {
                Text("本子还是空的").font(.title3.weight(.semibold))
                Text("在面板里按 ⌘I 打开词卡或句卡，再按 ⌘S 收进来，之后这里会按遗忘曲线安排复习。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else if due == 0 {
                Text("今天没有要复习的").font(.title3.weight(.semibold))
                if let next = notebook.entries.map(\.review.due).min() {
                    Text("下一次复习：\(next.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
            } else {
                Text("有 \(due) 个待复习").font(.title3.weight(.semibold))
                Text("先在心里回想，再看答案，然后诚实地选「忘了 / 模糊 / 记住」。")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                Button("开始复习") { session.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(40)
    }

    private func questionView(entry: NotebookEntry, question: ReviewQuestion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ProgressView(value: Double(session.graded), total: Double(max(session.total, 1)))
                Text("\(session.graded)/\(session.total)")
                    .font(Typography.ui(12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Text(question.instruction)
                .font(Typography.ui(12.5))
                .foregroundColor(.secondary)
            Text(question.prompt)
                .font(Font(Typography.result(size: 24)))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let hint = question.hint {
                Text(hint)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            if session.revealed {
                Divider()
                if !question.answer.isEmpty {
                    Text(question.answer)
                        .font(Font(Typography.result(size: 22)))
                        .foregroundColor(.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let detail = question.detail, detail != question.prompt {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                DisclosureGroup("完整卡片", isExpanded: $showsCard) {
                    ScrollView {
                        CardBlocksView(blocks: entry.blocks)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 220)
                }
                HStack(spacing: 10) {
                    Button("朗读") { Speaker.shared.speak(entry.surface) }
                    Spacer()
                    ForEach(Array(ReviewGrade.allCases.enumerated()), id: \.element) { index, grade in
                        Button {
                            showsCard = false
                            session.grade(grade)
                        } label: {
                            HStack(spacing: 6) {
                                Text(grade.displayName)
                                Keycap("\(index + 1)")
                            }
                            .frame(minWidth: 70)
                        }
                        .controlSize(.large)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                        .tint(grade == .forgot ? .red : grade == .good ? .green : .orange)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button {
                        session.reveal()
                    } label: {
                        HStack(spacing: 6) {
                            Text("显示答案")
                            Keycap("space")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
        .frame(maxWidth: 720)
    }

    private var summary: some View {
        VStack(spacing: 14) {
            Image(systemName: session.graded > 0 ? "party.popper" : "checkmark.seal")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text(session.graded > 0 ? "这一轮复习完成" : "今天没有要复习的")
                .font(.title3.weight(.semibold))
            if session.graded > 0 {
                HStack(spacing: 18) {
                    ForEach(ReviewGrade.allCases.reversed(), id: \.self) { grade in
                        VStack {
                            Text("\(session.counts[grade] ?? 0)").font(.title2.weight(.semibold))
                            Text(grade.displayName).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            if notebook.dueCount() > 0 {
                Button("再来一轮") { session.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}

// MARK: - 生词本 / 句型本

private struct NotebookTab: View {
    private enum Filter: String, CaseIterable {
        case all = "全部"
        case words = "生词"
        case patterns = "句型"
        case due = "待复习"
    }

    @ObservedObject var notebook: NotebookStore
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selection: UUID?

    private var visible: [NotebookEntry] {
        let now = Date()
        return notebook.entries.filter { entry in
            switch filter {
            case .all: break
            case .words: if entry.kind != .word { return false }
            case .patterns: if entry.kind == .word { return false }
            case .due: if entry.review.due > now { return false }
            }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            return entry.surface.localizedCaseInsensitiveContains(text)
                || entry.gloss.localizedCaseInsensitiveContains(text)
                || (entry.context ?? "").localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("搜索", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                List(selection: $selection) {
                    ForEach(visible) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.surface).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(entry.gloss).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                        }
                        .tag(entry.id)
                    }
                }
                .listStyle(.inset)
                HStack {
                    Menu("导出") {
                        Button("Markdown（Obsidian）…") { export(.markdown) }
                        Button("Anki（TSV）…") { export(.anki) }
                    }
                    .disabled(notebook.entries.isEmpty)
                    .fixedSize()
                    Spacer()
                    Text("\(visible.count) 条").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(width: 280)
            Divider()
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = notebook.entries.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Button { Speaker.shared.speak(entry.surface) } label: { Image(systemName: "speaker.wave.2") }
                    Button(role: .destructive) {
                        selection = nil
                        notebook.remove(id: entry.id)
                    } label: { Label("删除", systemImage: "trash") }
                }
                CardHeadline(text: entry.surface, kind: entry.kind, head: entry.blocks.head)
                Text(reviewLine(for: entry))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if let context = entry.context, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 13)).foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                ScrollView {
                    CardBlocksView(blocks: entry.blocks)
                        .padding(.trailing, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical").font(.system(size: 32)).foregroundColor(.secondary)
                Text(notebook.entries.isEmpty ? "还没有收进任何内容" : "选一条查看")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reviewLine(for entry: NotebookEntry) -> String {
        var parts = ["\(entry.kind.notebookName) · \(entry.createdAt.formatted(date: .abbreviated, time: .omitted)) 收进"]
        if let app = entry.appName { parts.append("来自 \(app)") }
        parts.append(entry.review.due <= Date() ? "待复习" : "下次复习 \(entry.review.due.formatted(date: .abbreviated, time: .omitted))")
        if !entry.reviews.isEmpty { parts.append("已复习 \(entry.reviews.count) 次") }
        return parts.joined(separator: " · ")
    }

    private enum ExportFormat { case markdown, anki }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .markdown: panel.nameFieldStringValue = "AIInput 生词本.md"
        case .anki: panel.nameFieldStringValue = "AIInput-anki.txt"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .markdown
            ? NotebookExporter.markdown(notebook.entries)
            : NotebookExporter.ankiTSV(notebook.entries)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

// MARK: - 统计

private struct StatsTab: View {
    @ObservedObject var notebook: NotebookStore
    @ObservedObject var lookups: LookupLog

    var body: some View {
        let stats = LearningStats.compute(lookups: lookups.records, entries: notebook.entries, now: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("最近 7 天").font(.headline)
                HStack(spacing: 28) {
                    metric("查过", "\(stats.weekLookups)", note: "其中新词/句 \(stats.weekNewKeys)")
                    metric("收进本子", "\(stats.weekSaved)")
                    metric("复习", "\(stats.weekReviews)")
                    metric("记住率", stats.weekRecallRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                }
                bars(stats.days)
                Divider()
                Text("本子").font(.headline)
                HStack(spacing: 28) {
                    metric("生词", "\(stats.words)")
                    metric("句型", "\(stats.patterns)")
                    metric("待复习", "\(stats.due)")
                    metric("已记牢", "\(stats.mastered)", note: "间隔 ≥ 3 周")
                }
                if !stats.repeated.isEmpty {
                    Divider()
                    Text("最近 30 天反复查的").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(stats.repeated, id: \.key) { item in
                            HStack {
                                Text(item.text).font(.system(size: 14, weight: .medium))
                                Text("查了 \(item.count) 次").font(.system(size: 12)).foregroundColor(.secondary)
                                Spacer()
                                Text(item.saved ? "已收进本子" : "还没收进本子，下次查到时按 ⌘S")
                                    .font(.system(size: 12))
                                    .foregroundColor(item.saved ? .secondary : .orange)
                            }
                        }
                    }
                }
                if lookups.records.isEmpty {
                    Text("查词记录为空：打开过的卡片会自动记在这里。可以在设置里关闭记录。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
            if let note { Text(note).font(.system(size: 11)).foregroundColor(.secondary) }
        }
    }

    private func bars(_ days: [LearningStats.Day]) -> some View {
        let peak = max(days.map { $0.lookups + $0.reviews }.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(days, id: \.date) { day in
                VStack(spacing: 4) {
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.green.opacity(0.7))
                            .frame(height: 70 * CGFloat(day.reviews) / CGFloat(peak))
                        Rectangle().fill(Color.accentColor.opacity(0.75))
                            .frame(height: 70 * CGFloat(day.lookups) / CGFloat(peak))
                    }
                    .frame(width: 30, height: 70)
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("查词", systemImage: "square.fill").foregroundColor(.accentColor)
                Label("复习", systemImage: "square.fill").foregroundColor(.green)
            }
            .font(.system(size: 11))
            .padding(.leading, 12)
        }
    }
}
