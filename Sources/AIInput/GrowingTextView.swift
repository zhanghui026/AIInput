import AppKit
import SwiftUI

/// 面板里的原文/结果编辑器。用 NSTextView 而不是 SwiftUI TextEditor：
/// 需要可靠的输入法组词判断（`hasMarkedText`）、按内容自动增高，以及拦截
/// Esc / ⇥ / ↑ 这些按键。
struct GrowingTextView: NSViewRepresentable {
    enum Command {
        case escape
        case tab
        case moveUpWhenEmpty
    }

    var text: String
    /// 有值时只读显示这段富文本（修订痕迹），否则显示并编辑 `text`。
    var attributedText: NSAttributedString?
    var font: NSFont
    var textColor: NSColor = .labelColor
    var isEditable = true
    var placeholder = ""
    var minHeight: CGFloat = 0
    var maxHeight: CGFloat = 320
    var autoFocus = false
    var selectAllOnFocus = false
    @Binding var height: CGFloat
    var onChange: (String) -> Void = { _ in }
    /// 返回 true 表示已处理，文本框不再执行默认行为。
    var onCommand: (Command) -> Bool = { _ in false }
    /// 把 NSTextView 交给外部（用于判断是否正在组词）。
    var onAttach: (NSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.textView = textView
        onAttach(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if attributedText == nil {
            // 修订痕迹自带颜色；统一设置字色会把红绿抹掉。
            textView.font = font
            textView.textColor = textColor
        }
        textView.insertionPointColor = textColor
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.placeholder = placeholder
        textView.placeholderFont = font
        if let attributedText {
            if !textView.attributedString().isEqual(to: attributedText) {
                textView.textStorage?.setAttributedString(attributedText)
            }
            context.coordinator.showsAttributedText = true
        } else if (textView.string != text || context.coordinator.showsAttributedText),
                  !textView.hasMarkedText() {
            // 组词中不能改写内容，否则会打断输入法。
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: textColor]
            ))
            context.coordinator.showsAttributedText = false
            textView.needsDisplay = true
        }
        context.coordinator.recalculateHeight()
        if autoFocus, !context.coordinator.didAutoFocus {
            context.coordinator.didAutoFocus = true
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                if selectAllOnFocus {
                    textView.selectAll(nil)
                } else {
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: PlaceholderTextView?
        var didAutoFocus = false
        var showsAttributedText = false

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            recalculateHeight()
            parent.onChange(textView.string)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.escape)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCommand(.tab)
            case #selector(NSResponder.moveUp(_:)) where textView.string.isEmpty:
                return parent.onCommand(.moveUpWhenEmpty)
            default:
                return false
            }
        }

        func recalculateHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let lineHeight = layout.defaultLineHeight(for: parent.font)
            let content = max(used, lineHeight) + textView.textContainerInset.height * 2
            let height = min(max(ceil(content), parent.minHeight), parent.maxHeight)
            guard abs(height - parent.height) > 0.5 else { return }
            DispatchQueue.main.async { [parent] in
                parent.height = height
            }
        }
    }
}

/// 带占位文字的 NSTextView。
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var placeholderFont: NSFont?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: placeholderFont ?? font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
