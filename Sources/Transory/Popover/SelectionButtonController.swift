import AppKit
import OSLog
import SwiftUI

/// 划词按钮的诊断日志（notice 级别，系统会留存）。
/// 查看：log show --last 10m --predicate 'subsystem == "app.transory.Transory"'
let selectionLog = Logger(subsystem: "app.transory.Transory", category: "selection")

/// 在其他 App 里选中文字后，在鼠标旁显示一个小的翻译按钮；点击后打开划词浮窗。
///
/// 只在「拖选 / 双击 / 三击 / Shift 点击」松开鼠标后检查选区；读不到选中文字时不打扰用户，
/// 例外是 Electron、网页这类不支持读取选区的文本区域，此时也显示按钮，点击时再用 ⌘C 兜底读取。
@MainActor
final class SelectionButtonController {
    static let size = NSSize(width: 30, height: 30)
    /// 按钮自动消失的时间。
    private static let lifetime: Duration = .seconds(4)
    /// 松开鼠标后读取选区的时机：有些 App 更新选区比较慢，读不到就再等一会儿重试。
    private static let retryDelays: [Duration] = [.milliseconds(60), .milliseconds(120), .milliseconds(220)]

    private let state: AppState
    private let popover: PopoverController
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var mouseDownLocation: NSPoint?
    /// 显示按钮时已读到的文字；为 nil 表示点击时再读取。
    private var pendingText: String?
    private var hideTask: Task<Void, Never>?

    init(state: AppState, popover: PopoverController) {
        self.state = state
        self.popover = popover
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            let clickCount = event.clickCount
            let shift = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated {
                self?.handleMouse(type: type, location: location, clickCount: clickCount, shift: shift)
            }
        }
        // 打字、滚动时收起按钮。
        let dismiss = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        monitors = [mouse, dismiss].compactMap { $0 }
    }

    // MARK: - 选区检测

    private func handleMouse(type: NSEvent.EventType, location: NSPoint, clickCount: Int, shift: Bool) {
        // 点在本 App 自己的窗口（翻译按钮、浮窗）上时不处理，否则按钮会在被点到之前就收起。
        // 只看最上层的窗口：被其他 App 挡住的主窗口、设置窗口不算。
        guard !NSApp.ownsTopmostWindow(at: location) else {
            if type == .leftMouseUp { selectionLog.notice("忽略：鼠标在 Transory 自己的窗口上") }
            return
        }
        switch type {
        case .leftMouseDown:
            hide()
            mouseDownLocation = location
        case .leftMouseUp:
            let dragged = mouseDownLocation.map { hypot($0.x - location.x, $0.y - location.y) > 6 } ?? false
            mouseDownLocation = nil
            guard dragged || clickCount >= 2 || shift else { return }
            Task { await checkSelection(at: location) }
        default:
            break
        }
    }

    private func checkSelection(at location: NSPoint) async {
        guard state.showSelectionButton else { return }
        guard Permissions.isGranted(.accessibility) else {
            selectionLog.notice("未显示：没有辅助功能权限")
            return
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let app = frontApp.localizedName ?? "?"

        // 0. Chrome、Electron 应用默认不开放网页的辅助功能信息，先请求开放，并给它一点时间建立。
        if SelectionReader.enableWebAccessibility(for: frontApp) {
            selectionLog.notice("已请求 \(app, privacy: .public) 开放网页辅助功能信息")
            try? await Task.sleep(for: .milliseconds(250))
        }

        // 1. 读聚焦控件的选区；还没更新就稍等重试。
        var last = SelectionReader.AXSelection.unsupported(role: nil)
        for delay in Self.retryDelays {
            try? await Task.sleep(for: delay)
            last = SelectionReader.accessibilitySelection(in: frontApp)
            switch last {
            case .text(let text):
                selectionLog.notice("显示按钮：\(app, privacy: .public) 聚焦控件有选中文字（\(text.count) 字）")
                show(at: location, text: text)
                return
            case .unsupported(let role?) where SelectionReader.textLikeRoles.contains(role):
                selectionLog.notice("显示按钮：\(app, privacy: .public) 的 \(role, privacy: .public) 不支持读取选区，点击时用 ⌘C 读取")
                show(at: location, text: nil)
                return
            case .empty, .unsupported(nil):
                continue
            case .unsupported:
                break
            }
            break
        }

        // 2. 聚焦控件读不到：改读鼠标所在位置的控件。
        switch SelectionReader.selectionUnderMouse(location) {
        case .text(let text):
            selectionLog.notice("显示按钮：\(app, privacy: .public) 鼠标下的控件有选中文字（\(text.count) 字）")
            show(at: location, text: text)
        case .unsupported(let role?):
            selectionLog.notice("显示按钮：\(app, privacy: .public) 鼠标下是 \(role, privacy: .public)，点击时用 ⌘C 读取")
            show(at: location, text: nil)
        default:
            // 3. 浏览器、Electron 应用读不到时仍显示按钮，点击时用 ⌘C 读取；读不到就提示音。
            if SelectionReader.isWebContentApp(frontApp) {
                selectionLog.notice("显示按钮：\(app, privacy: .public) 读不到选区信息，点击时用 ⌘C 读取")
                show(at: location, text: nil)
            } else {
                selectionLog.notice("未显示：\(app, privacy: .public) 没有读到选中文字（聚焦控件：\(String(describing: last), privacy: .public)）")
            }
        }
    }

    // MARK: - 按钮

    func show(at location: NSPoint, text: String?) {
        pendingText = text
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrameOrigin(origin(near: location))
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func buttonClicked() {
        let text = pendingText
        hide()
        if let text {
            popover.show(text)
        } else {
            Task { await popover.trigger() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = FirstClickHostingView(rootView: SelectionButton { [weak self] in self?.buttonClicked() })
        return panel
    }

    /// 放在鼠标右下方，不挡住选中的文字；超出屏幕时往回收。
    private func origin(near location: NSPoint) -> NSPoint {
        let size = Self.size
        var origin = NSPoint(x: location.x + 6, y: location.y - size.height - 6)
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = location.y + 6 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        return origin
    }
}

/// 本 App 不在前台时，第一次点击也直接触发按钮，而不是先用来激活窗口。
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 小圆按钮。
private struct SelectionButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "character.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: SelectionButtonController.size.width, height: SelectionButtonController.size.height)
                .background(Circle().fill(Color.accentColor.opacity(hovering ? 1 : 0.92)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("翻译选中文字")
        .accessibilityLabel("翻译选中文字")
    }
}

extension NSApplication {
    /// 屏幕上该位置最上层的窗口是否属于本 App。被其他 App 挡住的窗口不算。
    ///
    /// 不能用 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`：它只看本 App 自己的窗口，
    /// 主窗口被其他 App 挡住时也会命中，导致在那片区域选字时按钮永远不出现。
    /// 这里用系统窗口列表（按从前到后排序）找真正最上层的窗口。
    func ownsTopmostWindow(at location: NSPoint) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        // 窗口列表用左上角为原点的全局坐标。
        let point = CGPoint(x: location.x, y: primaryHeight - location.y)
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infos {
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(point)
            else { continue }
            return (info[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
        }
        return false
    }
}
