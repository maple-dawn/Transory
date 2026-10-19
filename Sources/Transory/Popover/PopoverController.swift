import AppKit
import Observation
import SwiftUI
import TransoryCore

/// 划词翻译：读取选中文本 → 在鼠标旁弹出浮窗 → 主模型和对比模型各一张结果卡片，流式显示译文。
@MainActor
@Observable
final class PopoverController {
    /// 普通宽度；原文较长时加宽，减少滚动。
    static let narrowWidth: CGFloat = 440
    static let wideWidth: CGFloat = 580
    private static let collapsedKey = "popoverCollapsedProviders"

    let state: AppState
    /// 原文，可在浮窗里直接修改后重译。
    var sourceText = ""
    var source: Language = .auto
    var target: Language = .simplifiedChinese
    var isPinned = false
    /// 本次参与翻译的服务商：主模型在前，其后是勾选了「参与对比」的模型。
    private(set) var providerIDs: [String] = []
    /// 原文的识别语言，翻译时更新。
    private(set) var detected: Language?
    /// 折叠起来的服务商，跨次记住。
    private(set) var collapsed: Set<String>

    /// 浮窗宽度，随原文长度决定。
    private(set) var width = PopoverController.narrowWidth
    /// 工具栏以下的内容最多可占的高度，超出才滚动；由所在屏幕高度决定。
    private(set) var maxBodyHeight: CGFloat = 480

    @ObservationIgnored private var panel: PopoverPanel?
    @ObservationIgnored private var hostingView: NSView?
    @ObservationIgnored private var outsideClickMonitor: Any?

    var session: TranslationSession { state.popover }
    var request: TranslateRequest? { session.lastRequest }

    var providers: [ProviderConfig] {
        providerIDs.compactMap { state.provider(id: $0) }
    }

    func result(for id: String) -> ModelResult? {
        session.results[id]
    }

    init(state: AppState) {
        self.state = state
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    // MARK: - 触发

    func trigger() async {
        guard Permissions.isGranted(.accessibility) else {
            Permissions.request(.accessibility)
            return
        }
        guard let text = await SelectionReader.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            NSSound.beep()
            return
        }
        show(text)
    }

    func show(_ text: String) {
        sourceText = text
        source = .auto
        target = state.target
        translate()
        present()
    }

    // MARK: - 翻译

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var configs = state.providers(for: .popover)
        if configs.isEmpty, let primary = state.primaryProvider { configs = [primary] }
        providerIDs = configs.map(\.id)
        detected = LanguageDetector.detect(text)
        state.popoverHistoryEntry = nil
        let request = state.makeRequest(text: text, source: source, target: target, style: state.style)
        session.run(request, providers: configs.map(state.makeTranslator))
    }

    func setSource(_ language: Language) {
        source = language
        translate()
    }

    func setTarget(_ language: Language) {
        target = language
        translate()
    }

    /// 交换语言：源语言为「自动」时，用识别出的语言作为新的目标语言。
    func swapLanguages() {
        let from = source == .auto ? (detected ?? .english) : source
        source = request?.target ?? target
        target = from
        translate()
    }

    func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    // MARK: - 卡片操作

    func copy(_ id: String) {
        if let text = result(for: id)?.text, !text.isEmpty { state.copy(text) }
    }

    func speak(_ id: String) {
        SpeechPlayer.shared.speak(result(for: id)?.text ?? "", language: request?.target)
    }

    func speakSource() {
        SpeechPlayer.shared.speak(sourceText, language: detected)
    }

    /// 用译文替换原 App 中选中的文字。
    func replace(_ id: String) {
        guard let text = result(for: id)?.text, !text.isEmpty else { return }
        // 粘贴要发给原 App，浮窗得先让出键盘焦点；钉住时只是暂时隐藏，粘贴完再显示回来。
        let pinned = isPinned
        if pinned { panel?.orderOut(nil) } else { close() }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            await SelectionReader.paste(text)
            if pinned { panel?.orderFrontRegardless() }
        }
    }

    /// 设为浮窗的默认服务：排到第一位，历史记录也以它为准。
    func makeDefault(_ id: String) {
        state.moveToFront(id, in: .popover)
        providerIDs = [id] + providerIDs.filter { $0 != id }
    }

    // MARK: - 工具栏

    var historyEntry: HistoryEntry? { state.popoverHistoryEntry }

    func toggleFavorite() {
        if let entry = historyEntry { state.toggleFavorite(entry) }
    }

    /// 钉住时，跳到别处（历史、截图、主窗口）也保留浮窗。
    private func dismissUnlessPinned() {
        if !isPinned { close() }
    }

    func openHistory() {
        dismissUnlessPinned()
        state.navigation = .history
        state.showMainWindow()
    }

    func startScreenshot() {
        dismissUnlessPinned()
        state.startScreenshot?()
    }

    func openInMain() {
        guard let request else { return }
        let id = providerIDs.first
        dismissUnlessPinned()
        state.presentInMain(request: request, result: id.flatMap(result(for:)), providerID: id)
    }

    // MARK: - 浮窗

    private func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 长原文用宽版；工具栏以下最多占屏幕可用高度的 80%。
        width = sourceText.count > 280 ? Self.wideWidth : Self.narrowWidth
        maxBodyHeight = max(200, visible.height * 0.8 - 44)

        let panel = panel ?? makePanel()
        self.panel = panel
        // 先放在鼠标右下方，高度在 fitToContent 里按内容调整。
        let x = min(max(mouse.x - 24, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: mouse.y - 18 - panel.frame.height, width: width, height: panel.frame.height), display: false)
        fitToContent()
        panel.orderFrontRegardless()
        panel.makeKey()
        // 不让原文输入框自动获得焦点，否则原文会被全选，一按键就被覆盖。
        panel.makeFirstResponder(nil)

        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let location = NSEvent.mouseLocation
                MainActor.assumeIsolated {
                    // 浮窗不激活本 App，点击浮窗自身的按钮也会被全局监听收到，要排除掉。
                    guard let self, !self.isPinned, !NSApp.hasVisibleWindow(at: location) else { return }
                    self.close()
                }
            }
        }
    }

    /// 按内容调整浮窗大小：顶边保持不动向下长；碰到屏幕底边时整体上移。
    func fitToContent() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.height > 0 else { return }
        let top = panel.frame.maxY
        var frame = NSRect(x: panel.frame.minX, y: top - size.height, width: width, height: size.height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        }
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    func close() {
        panel?.orderOut(nil)
        isPinned = false
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func makePanel() -> PopoverPanel {
        let hosting = NSHostingView(rootView: PopoverView(controller: self).environment(state))
        // 内容铺满整个面板（包括透明标题栏区域），尺寸计算也不额外留出标题栏高度。
        hosting.safeAreaRegions = []
        hostingView = hosting
        let panel = PopoverPanel(contentView: hosting, size: NSSize(width: Self.narrowWidth, height: 240))
        panel.onEscape = { [weak self] in self?.close() }
        return panel
    }
}

/// 不抢焦点的浮动面板：原 App 保持在前台，所以「替换原文」能粘贴回去。
final class PopoverPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(contentView: NSView, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}
