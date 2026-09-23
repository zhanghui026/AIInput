import ApplicationServices
import Cocoa

/// 通过辅助功能 API 读取目标 App 的焦点元素、选中文本，并判断能否替换文本。
enum SelectionReader {
    static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &value) == .success,
              let focused = value,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = focused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == app.processIdentifier else {
            return nil
        }
        return element
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
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success {
            return settable.boolValue
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return true
        }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }
}
