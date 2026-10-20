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
    /// 优先从前台 App 读取聚焦控件，比系统级的查询更可靠。
    static func accessibilitySelection(in app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> AXSelection {
        guard AXIsProcessTrusted() else { return .unsupported(role: nil) }
        let owner = app.map { AXUIElementCreateApplication($0.processIdentifier) } ?? AXUIElementCreateSystemWide()
        // 避免卡在无响应的 App 上。
        AXUIElementSetMessagingTimeout(owner, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .unsupported(role: nil) }
        return selection(of: focused as! AXUIElement)
    }

    // MARK: - 浏览器与 Electron 应用

    /// Chromium 内核浏览器的 bundle id。
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// 是否是网页内容默认不开放辅助功能信息的 App（Chromium 浏览器、Electron 应用）。
    static func isWebContentApp(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, chromiumBrowsers.contains(id) { return true }
        guard let bundle = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
    }

    private static var boostedApps: Set<pid_t> = []

    /// 请求 App 开放网页内容的辅助功能信息（VoiceOver、PopClip 等工具也是这样做的）。
    /// 每个进程只请求一次；返回 true 表示刚刚请求过，需要稍等它建立信息。
    static func enableWebAccessibility(for app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard isWebContentApp(app), !boostedApps.contains(pid) else { return false }
        boostedApps.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        // Electron 认 AXManualAccessibility；Chromium 浏览器认 AXEnhancedUserInterface。
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }

    /// 兜底：读鼠标所在位置的控件（及其上几层父控件）的选区。
    /// 有些 App 报告不出聚焦控件，或者选区不在聚焦控件里，这时从鼠标位置找。
    static func selectionUnderMouse(_ location: NSPoint) -> AXSelection {
        guard AXIsProcessTrusted() else { return .unsupported(role: nil) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        // 辅助功能用左上角为原点的全局坐标。
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(primaryHeight - location.y), &hit) == .success,
              var element = hit
        else { return .unsupported(role: nil) }

        var firstRole: String?
        for _ in 0..<5 {
            let result = selection(of: element)
            switch result {
            case .text: return result
            case .unsupported(let role):
                if firstRole == nil, let role, textLikeRoles.contains(role) { firstRole = role }
            case .empty:
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            element = parent as! AXUIElement
        }
        return .unsupported(role: firstRole)
    }

    /// 不支持读取选区、但多半是文本区域的控件类型（网页、Electron、文本框）。
    static let textLikeRoles: Set<String> = ["AXWebArea", "AXTextArea", "AXTextField", "AXStaticText", "AXGroup"]

    private static func selection(of element: AXUIElement) -> AXSelection {
        AXUIElementSetMessagingTimeout(element, 0.25)
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
