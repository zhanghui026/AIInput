import Cocoa

/// 设置窗口：API Key / Base URL / 模型。
final class SettingsWindowController: NSWindowController {
    private let apiKeyField = NSSecureTextField()
    private let baseUrlField = NSTextField()
    private let modelField = NSTextField()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "AIInput 设置"
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
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 22, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "模型服务")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "配置 Anthropic Messages 兼容接口。API Key 会保存在本机，并同步到 ~/.aiinput/key。")
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        apiKeyField.placeholderString = "API Key"
        baseUrlField.placeholderString = "https://api.minimaxi.com/anthropic/v1"
        modelField.placeholderString = "MiniMax-M3"

        apiKeyField.stringValue = Config.apiKey
        baseUrlField.stringValue = Config.baseUrl
        modelField.stringValue = Config.model

        content.addArrangedSubview(title)
        content.addArrangedSubview(subtitle)
        content.setCustomSpacing(20, after: subtitle)
        content.addArrangedSubview(row(label: "API Key", field: apiKeyField))
        content.addArrangedSubview(row(label: "Base URL", field: baseUrlField))
        content.addArrangedSubview(row(label: "模型", field: modelField))

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.bezelStyle = .push
        saveBtn.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), saveBtn])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill
        content.addArrangedSubview(buttonRow)

        window?.contentView = content
        let cw = window!.contentView!
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cw.topAnchor),
            content.bottomAnchor.constraint(equalTo: cw.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: cw.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cw.trailingAnchor),
            subtitle.widthAnchor.constraint(equalTo: content.widthAnchor,
                                             constant: -(content.edgeInsets.left + content.edgeInsets.right)),
            apiKeyField.widthAnchor.constraint(equalToConstant: 350),
            baseUrlField.widthAnchor.constraint(equalToConstant: 350),
            modelField.widthAnchor.constraint(equalToConstant: 350),
            buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor,
                                             constant: -(content.edgeInsets.left + content.edgeInsets.right)),
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
