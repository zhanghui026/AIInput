import Cocoa

/// 设置窗口：API Key / Base URL / 模型。
final class SettingsWindowController: NSWindowController {
    private let apiKeyField = NSTextField()
    private let baseUrlField = NSTextField()
    private let modelField = NSTextField()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "AI 翻译输入助手 — 设置"
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        apiKeyField.placeholderString = "留空则用环境变量 MINIMAX_API_KEY"
        baseUrlField.placeholderString = "https://api.minimaxi.com/anthropic/v1"
        modelField.placeholderString = "MiniMax-M3"

        apiKeyField.stringValue = Config.apiKey
        baseUrlField.stringValue = Config.baseUrl
        modelField.stringValue = Config.model

        content.addArrangedSubview(row(label: "API Key", field: apiKeyField))
        content.addArrangedSubview(row(label: "Base URL", field: baseUrlField))
        content.addArrangedSubview(row(label: "模型", field: modelField))

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        content.addArrangedSubview(saveBtn)

        window?.contentView = content
        let cw = window!.contentView!
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cw.topAnchor),
            content.bottomAnchor.constraint(equalTo: cw.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: cw.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cw.trailingAnchor),
            apiKeyField.widthAnchor.constraint(equalTo: cw.widthAnchor, multiplier: 0.7),
            baseUrlField.widthAnchor.constraint(equalTo: cw.widthAnchor, multiplier: 0.7),
            modelField.widthAnchor.constraint(equalTo: cw.widthAnchor, multiplier: 0.7),
        ])
    }

    private func row(label: String, field: NSTextField) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.alignment = .right
        lbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [lbl, field])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.distribution = .fill
        lbl.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return stack
    }

    @objc private func save() {
        Config.apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.baseUrl = baseUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.close()
    }

    func show() {
        apiKeyField.stringValue = Config.apiKey
        baseUrlField.stringValue = Config.baseUrl
        modelField.stringValue = Config.model
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(apiKeyField)
    }
}
