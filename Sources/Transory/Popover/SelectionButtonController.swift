import AppKit
import SwiftUI

/// 在其他 App 里选中文字后，在鼠标旁显示一个小的翻译按钮；点击后打开划词浮窗。
///
/// 只在「拖选 / 双击 / 三击 / Shift 点击」松开鼠标后检查选区；读不到选中文字时不打扰用户，
/// 例外是 Electron、网页这类不支持读取选区的文本区域，此时也显示按钮，点击时再用 ⌘C 兜底读取。
@MainActor
final class SelectionButtonController {
    static let size = NSSize(width: 30, height: 30)
    /// 按钮自动消失的时间。
    private static let lifetime: Duration = .seconds(4)
    /// 不支持读取选区、但多半是文本区域的控件类型。
    private static let textLikeRoles: Set<String> = ["AXWebArea", "AXTextArea", "AXTextField", "AXStaticText", "AXGroup"]

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
        guard !NSApp.hasVisibleWindow(at: location) else { return }
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
        guard state.showSelectionButton,
              Permissions.isGranted(.accessibility),
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        // 等目标 App 更新完选区。
        try? await Task.sleep(for: .milliseconds(80))

        switch SelectionReader.accessibilitySelection() {
        case .text(let text):
            show(at: location, text: text)
        case .unsupported(let role) where role.map(Self.textLikeRoles.contains) == true:
            show(at: location, text: nil)
        case .empty, .unsupported:
            break
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
    /// 屏幕上该位置是否有本 App 的可见窗口。
    func hasVisibleWindow(at location: NSPoint) -> Bool {
        windows.contains { $0.isVisible && $0.frame.contains(location) }
    }
}
