import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 读取其他 App 中选中的文字，以及把文字粘贴回去。都需要辅助功能权限。
@MainActor
enum SelectionReader {
    static func read() async -> String? {
        if let text = readViaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return await readViaCopy()
    }

    /// 通过辅助功能读到的选区状态。
    enum AXSelection: Equatable {
        /// 读到了非空的选中文字。
        case text(String)
        /// 控件支持读取，但当前没有选中文字。
        case empty
        /// 控件不支持读取选中文字（常见于 Electron、部分网页），`role` 为聚焦控件的类型。
        case unsupported(role: String?)
    }

    /// 首选：直接读当前聚焦控件的选中文本。原生 App 大多支持，部分 Electron/网页不支持。
    static func accessibilitySelection() -> AXSelection {
        guard AXIsProcessTrusted() else { return .unsupported(role: nil) }
        let system = AXUIElementCreateSystemWide()
        // 避免卡在无响应的 App 上。
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .unsupported(role: nil) }
        let element = focused as! AXUIElement

        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success {
            let text = (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? .empty : .text(text)
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return .unsupported(role: role as? String)
    }

    private static func readViaAccessibility() -> String? {
        if case .text(let text) = accessibilitySelection() { return text }
        return nil
    }

    /// 兜底：模拟 ⌘C 再读剪贴板，读完恢复用户原来的剪贴板内容。
    private static func readViaCopy() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        postKey(kVK_ANSI_C, flags: .maskCommand)
        for _ in 0..<8 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let text = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
        if pasteboard.changeCount != before {
            restore(saved, to: pasteboard)
        }
        return text
    }

    /// 把文字粘贴到当前前台 App（用于「替换原文」）。调用前要先关掉自己的浮窗。
    static func paste(_ text: String) async {
        guard AXIsProcessTrusted() else {
            Permissions.request(.accessibility)
            return
        }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKey(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(300))
        restore(saved, to: pasteboard)
    }

    private static func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
