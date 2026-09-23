import ApplicationServices
import Cocoa

/// 通过辅助功能 API 读取目标 App 的焦点元素、选区状态，并判断能否替换文本。
enum SelectionReader {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// 目标 App 自己的焦点元素。按 App 查询而不是系统级查询：
    /// 面板成为 key window 之后仍能拿到原 App 里的输入框。
    static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let element = elementAttribute(kAXFocusedUIElementAttribute, of: appElement) {
            return element
        }

        guard let element = elementAttribute(
            kAXFocusedUIElementAttribute,
            of: AXUIElementCreateSystemWide()
        ) else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == app.processIdentifier else {
            return nil
        }
        return element
    }

    enum SelectionState: Equatable {
        case text(String)  // 读到了选中文字
        case none          // 能确定没有选区（原生输入框、光标只是一个点）
        case unknown       // 读不到（Electron/网页等），需要用 ⌘C 探测
    }

    /// 通过辅助功能判断选区；读不准时返回 `.unknown`，由调用方改用 ⌘C。
    static func selectionState(in element: AXUIElement?) -> SelectionState {
        guard let element else { return .unknown }
        if isSecureTextElement(element) { return .none }
        if let text = selectedText(from: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return .text(text)
        }
        guard isTextInput(element) else { return .unknown }
        var rangeValue: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID(),
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return .unknown
        }
        return range.length == 0 ? .none : .unknown
    }

    /// 焦点是否在可输入文字的控件里（而不是网页文档、列表等）。
    static func isTextInput(_ element: AXUIElement?) -> Bool {
        guard let element, !isSecureTextElement(element) else { return false }
        return role(of: element).map(textRoles.contains) ?? false
    }

    private static func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func selectedText(from element: AXUIElement?) -> String? {
        guard let element else { return nil }
        for candidate in elementAndAncestors(startingAt: element) {
            guard !isSecureTextElement(candidate) else { return nil }
            if let text = directSelectedText(from: candidate), !text.isEmpty {
                return text
            }
            if let text = textMarkerSelection(from: candidate), !text.isEmpty {
                return text
            }
            if let text = rangeSelection(from: candidate), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success
            && (subroleValue as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private static func elementAndAncestors(
        startingAt element: AXUIElement,
        maximumDepth: Int = 12
    ) -> [AXUIElement] {
        var elements: [AXUIElement] = []
        var visited: Set<CFHashCode> = []
        var current: AXUIElement? = element
        while let candidate = current, elements.count < maximumDepth {
            let hash = CFHash(candidate)
            guard visited.insert(hash).inserted else { break }
            elements.append(candidate)

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
            let parentValue,
            CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                break
            }
            current = (parentValue as! AXUIElement)
        }
        return elements
    }

    private static func directSelectedText(from element: AXUIElement) -> String? {
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
        let selectedText = selectedValue as? String else {
            return nil
        }
        return selectedText
    }

    private static func textMarkerSelection(from element: AXUIElement) -> String? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        ) == .success,
        let markerRange,
        CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }

        var attributedValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXAttributedStringForTextMarkerRange" as CFString,
            markerRange,
            &attributedValue
        ) == .success,
        let attributedValue else {
            return nil
        }
        if let attributedString = attributedValue as? NSAttributedString {
            return attributedString.string
        }
        guard CFGetTypeID(attributedValue) == CFAttributedStringGetTypeID() else {
            return nil
        }
        let attributedString = attributedValue as! CFAttributedString
        return CFAttributedStringGetString(attributedString) as String
    }

    private static func rangeSelection(from element: AXUIElement) -> String? {
        // 一些 App 不直接暴露 AXSelectedText，但会提供完整文本和选区范围。
        var rangeValue: CFTypeRef?
        var fullValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID(),
        AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &fullValue
        ) == .success,
        let fullText = fullValue as? String else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0 else {
            return nil
        }
        let nsRange = NSRange(location: range.location, length: range.length)
        guard NSMaxRange(nsRange) <= (fullText as NSString).length else {
            return nil
        }
        return (fullText as NSString).substring(with: nsRange)
    }

    static func canReplaceText(in element: AXUIElement?) -> Bool {
        guard let element else { return true }
        if isTextInput(element) {
            return true
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success {
            return settable.boolValue
        }
        return role(of: element) == nil
    }
}
