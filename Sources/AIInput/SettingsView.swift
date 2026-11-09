import AppKit
import SwiftUI

/// 设置的草稿：改动先留在这里，点「保存」才写入配置。
@MainActor
final class SettingsModel: ObservableObject {
    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case ok(TimeInterval)
        case failed(String)
    }

    @Published var apiKey = ""
    @Published var baseURL = ""
    @Published var model = ""
    @Published var hotkey = Hotkey.default
    @Published var favoriteTones: [WritingTone] = []
    @Published var customInstructions = ""
    @Published var autoPaste = false
    @Published var historyEnabled = true
    @Published var lookupLogEnabled = true
    @Published var connection: ConnectionStatus = .idle
    @Published var fallbackEnabled = false
    @Published var fallbackModel = ""
    @Published var fallbackConnection: ConnectionStatus = .idle
    @Published var hotkeyError: String?
    @Published var notice: String?

    private var connectionTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    func load() {
        apiKey = Config.apiKey
        baseURL = Config.baseUrl
        model = Config.model
        hotkey = Config.hotkey
        favoriteTones = Config.favoriteTones
        customInstructions = Config.customInstructions
        autoPaste = Config.autoPaste
        historyEnabled = Config.historyEnabled
        lookupLogEnabled = Config.lookupLogEnabled
        fallbackEnabled = Config.fallbackEnabled
        fallbackModel = Config.fallbackModel
        connection = .idle
        fallbackConnection = .idle
        hotkeyError = nil
        notice = nil
    }

    /// 写入配置；热键被占用时不关闭窗口并提示。
    func save(applyHotkey: (Hotkey) -> Bool) -> Bool {
        if hotkey != Config.hotkey, !applyHotkey(hotkey) {
            hotkeyError = "\(hotkey.displayString) 已被其他 App 占用，请换一个。"
            return false
        }
        Config.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.baseUrl = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.fallbackEnabled = fallbackEnabled
        Config.fallbackModel = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.favoriteTones = favoriteTones
        Config.customInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.autoPaste = autoPaste
        Config.historyEnabled = historyEnabled
        Config.lookupLogEnabled = lookupLogEnabled
        return true
    }

    func toggleFavorite(_ tone: WritingTone) {
        favoriteTones = FavoriteTones.toggle(tone, in: favoriteTones)
    }

    /// 用当前（未保存的）配置发一条很短的请求，确认 key、地址和模型都能用。
    func testConnection() {
        connectionTask?.cancel()
        connection = .testing
        let config = ServiceConfig(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let service = TranslationService(config: { config }, retryDelays: [], fallback: nil)
        let started = Date()
        connectionTask = Task { [weak self] in
            do {
                _ = try await service.perform(TransformationRequest(mode: .polish, tone: .faithful, text: "Hello."))
                self?.connection = .ok(Date().timeIntervalSince(started))
            } catch is CancellationError {
                return
            } catch {
                self?.connection = .failed(error.localizedDescription)
            }
        }
    }

    /// 直接用 droid 跑一次很短的润色，不经过主服务。
    func testFallback() {
        fallbackTask?.cancel()
        let config = FallbackConfig(
            enabled: true,
            model: fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        fallbackConnection = .testing
        let fallback = DroidFallback(config: { config })
        let started = Date()
        fallbackTask = Task { [weak self] in
            do {
                let prompt = try TransformationPromptBuilder.make(
                    for: TransformationRequest(mode: .polish, tone: .faithful, text: "Hello.")
                )
                _ = try await fallback.run(prompt)
                self?.fallbackConnection = .ok(Date().timeIntervalSince(started))
            } catch is CancellationError {
                return
            } catch {
                self?.fallbackConnection = .failed(error.localizedDescription)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var history: HistoryStore
    @ObservedObject var lookups: LookupLog
    let onResetPosition: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                serviceSection
                fallbackSection
                hotkeySection
                tonesSection
                instructionsSection
                behaviorSection
            }
            .formStyle(.grouped)

            HStack {
                if let notice = settings.notice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 700)
    }

    private var serviceSection: some View {
        Section {
            SecureField("API Key", text: $settings.apiKey, prompt: Text("保存在 ~/.aiinput/key"))
            TextField("Base URL", text: $settings.baseURL, prompt: Text("https://api.minimaxi.com/anthropic/v1"))
            TextField("模型", text: $settings.model, prompt: Text("MiniMax-M3"))
            HStack(spacing: 10) {
                Button("测试连接", action: settings.testConnection)
                    .disabled(settings.connection == .testing)
                connectionLabel
            }
        } header: {
            Text("模型服务")
        } footer: {
            Text("Anthropic Messages 兼容接口。API Key 只保存在 ~/.aiinput/key（仅你可读）。测试连接会发一条很短的请求。")
        }
    }

    private var fallbackSection: some View {
        Section {
            Toggle("主服务失败时改用 Droid", isOn: $settings.fallbackEnabled)
            if settings.fallbackEnabled {
                TextField("模型", text: $settings.fallbackModel, prompt: Text("留空用 droid 的默认模型"))
                HStack(spacing: 10) {
                    Button("测试备用", action: settings.testFallback)
                        .disabled(settings.fallbackConnection == .testing)
                    statusLabel(settings.fallbackConnection)
                }
            }
        } header: {
            Text("备用")
        } footer: {
            Text("主服务失败或未配置时，改用本机已登录的 droid exec 生成（只读、在空的临时目录里运行，不流式，通常要 5–30 秒）。")
        }
    }

    private var connectionLabel: some View {
        statusLabel(settings.connection)
    }

    @ViewBuilder
    private func statusLabel(_ status: SettingsModel.ConnectionStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok(let seconds):
            Label(String(format: "连接正常 · %.1f 秒", seconds), systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundColor(.red)
                .font(.system(size: 12))
                .lineLimit(2)
        }
    }

    private var hotkeySection: some View {
        Section {
            HStack {
                Text("唤起面板")
                Spacer()
                HotkeyRecorder(hotkey: settings.hotkey) { hotkey in
                    settings.hotkey = hotkey
                    settings.hotkeyError = nil
                }
                .frame(width: 150, height: 26)
                Button("恢复默认") {
                    settings.hotkey = .default
                    settings.hotkeyError = nil
                }
                .disabled(settings.hotkey == .default)
            }
            if let error = settings.hotkeyError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        } header: {
            Text("快捷键")
        } footer: {
            Text("点击后按下新的组合键，至少包含 ⌘、⌥ 或 ⌃；按 Esc 取消录制。")
        }
    }

    private var tonesSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(WritingTone.allCases, id: \.self) { tone in
                    let isOn = settings.favoriteTones.contains(tone)
                    Button {
                        settings.toggleFavorite(tone)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            Text(tone.chipName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isOn ? .accentColor : .primary)
                    .disabled(!isOn && !FavoriteTones.canAdd(to: settings.favoriteTones))
                }
            }
        } header: {
            Text("常用语气（\(settings.favoriteTones.count)/\(FavoriteTones.limit)）")
        } footer: {
            Text("面板上直接显示、按 ⌘1–⌘5 切换；前 4 个也是多语气视图的「常用」分组。")
        }
    }

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $settings.customInstructions)
                .font(.system(size: 13))
                .frame(height: 76)
        } header: {
            Text("个人要求 / 术语表")
        } footer: {
            Text("每次翻译、润色和微调都会遵守。例如：「大模型」译为 LLM；英文用美式拼写。")
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle("结果生成后直接粘贴（跳过预览）", isOn: $settings.autoPaste)
            Toggle("记录用过的结果（⌘Y 历史，仅保存在本机）", isOn: $settings.historyEnabled)
            Toggle("记录打开过的学习卡片（「第 N 次查」和学习统计）", isOn: $settings.lookupLogEnabled)
            HStack {
                Button("清空历史（\(history.entries.count) 条）", action: history.clear)
                    .disabled(history.entries.isEmpty)
                Button("清空查词记录（\(lookups.records.count) 条）", action: lookups.clear)
                    .disabled(lookups.records.isEmpty)
                Button("重置面板位置", action: onResetPosition)
                    .help("忘记拖动过的位置，面板重新贴在文字下方或屏幕上方居中")
            }
        } header: {
            Text("使用习惯")
        } footer: {
            Text("查词记录和生词本只存在本机 ~/Library/Application Support/AIInput（仅你可读）。收进生词本时会连同选中文字所在的那一句一起保存，用来出复习题。")
        }
    }
}

/// 点击后录制下一组快捷键。
private struct HotkeyRecorder: NSViewRepresentable {
    let hotkey: Hotkey
    let onRecord: (Hotkey) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.hotkey = hotkey
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
        view.hotkey = hotkey
    }

    final class RecorderView: NSView {
        var onRecord: ((Hotkey) -> Void)?
        var hotkey = Hotkey.default {
            didSet { needsDisplay = true }
        }
        private var isRecording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            isRecording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            record(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }
            record(event)
        }

        private func record(_ event: NSEvent) {
            if event.keyCode == 53 {
                isRecording = false
                return
            }
            guard let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags) else {
                NSSound.beep()
                return
            }
            isRecording = false
            onRecord?(hotkey)
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 1.5 : 1
            path.stroke()

            let text = isRecording ? "按下新的快捷键…" : hotkey.displayString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}
