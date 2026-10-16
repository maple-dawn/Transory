#if DEBUG
import AppKit
import SwiftData
import TransoryCore

/// 开发用：设置环境变量 `TRANSORY_SNAPSHOT_DIR` 启动时，把各个窗口渲染成 PNG 后退出。
/// - 在进程内渲染，不需要屏幕录制权限。
/// - 使用内存数据库和示例数据，不读写真实历史；翻译走本地假模型，不发网络请求。
@MainActor
enum SnapshotTool {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["TRANSORY_SNAPSHOT_DIR"] != nil
    }

    static func runIfRequested(state: AppState, features: Features) {
        guard let dir = ProcessInfo.processInfo.environment["TRANSORY_SNAPSHOT_DIR"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            seed(state)
            try? await Task.sleep(for: .seconds(2))

            state.sourceText = "The best tools disappear into the workflow. Select any text, press ⌥ D, and the translation appears right where you are."
            state.translate()
            try? await Task.sleep(for: .seconds(1))
            save(mainWindow(), to: "\(dir)/main.png")

            for item in [SidebarItem.history, .glossary] {
                state.navigation = item
                try? await Task.sleep(for: .seconds(1))
                save(mainWindow(), to: "\(dir)/\(item.rawValue).png")
            }

            features.selectionButton.show(at: NSEvent.mouseLocation, text: "Latency is a feature.")
            try? await Task.sleep(for: .milliseconds(500))
            save(NSApp.windows.first { $0.isVisible && $0.frame.size == SelectionButtonController.size }, to: "\(dir)/selection-button.png")
            features.selectionButton.hide()

            features.popover.show("Latency is a feature. Users forgive a plain interface long before they forgive a slow one.")
            try? await Task.sleep(for: .seconds(1))
            save(NSApp.windows.first { $0 is PopoverPanel && $0.isVisible }, to: "\(dir)/popover.png")
            features.popover.close()

            let longText = Array(repeating: "Good tools stay out of the way. They show up when you need them and disappear when you do not, so the work itself stays in focus.", count: 5).joined(separator: " ")
            features.popover.show(longText)
            try? await Task.sleep(for: .seconds(1))
            print("snapshot: 浮窗 \(NSApp.windows.filter { $0 is PopoverPanel }.map { "\($0.isVisible) \($0.frame)" })")
            save(NSApp.windows.first { $0 is PopoverPanel && $0.isVisible }, to: "\(dir)/popover-long.png")
            features.popover.close()

            if let image = sampleImage() {
                await features.ocr.load(image)
                try? await Task.sleep(for: .seconds(1))
                save(features.ocr.windowForSnapshot, to: "\(dir)/ocr.png")
                features.ocr.mode = .overlay
                try? await Task.sleep(for: .milliseconds(500))
                save(features.ocr.windowForSnapshot, to: "\(dir)/ocr-overlay.png")
            }

            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
            }
            try? await Task.sleep(for: .seconds(1.5))
            if let settings = NSApp.windows.first(where: { $0.isVisible && $0.title == "通用" }) {
                save(settings, to: "\(dir)/settings-general.png")
                state.settingsTab = .services
                try? await Task.sleep(for: .seconds(1))
                save(settings, to: "\(dir)/settings-services.png")
                state.isAddingProvider = true
                try? await Task.sleep(for: .seconds(1))
                save(settings.attachedSheet, to: "\(dir)/add-provider.png")
                state.isAddingProvider = false
                try? await Task.sleep(for: .milliseconds(500))
                // 直接切外观（不改 state.theme，避免写入用户设置），检查浅色主题。
                NSApp.appearance = NSAppearance(named: .aqua)
                try? await Task.sleep(for: .milliseconds(800))
                save(settings, to: "\(dir)/settings-light.png")
                state.navigation = .translate
                try? await Task.sleep(for: .milliseconds(500))
                save(mainWindow(), to: "\(dir)/main-light.png")
                features.popover.show("Ship it behind a feature flag.")
                try? await Task.sleep(for: .seconds(1))
                save(NSApp.windows.first { $0 is PopoverPanel && $0.isVisible }, to: "\(dir)/popover-light.png")
                features.popover.close()
            }
            NSApp.terminate(nil)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
    }

    private static func seed(_ state: AppState) {
        let samples: [(String, String, String, Bool)] = [
            ("Latency is a feature.", "低延迟本身就是一项功能。", "popover", true),
            ("Die Rechnung ist überfällig.", "这张发票已经逾期。", "main", false),
            ("取り急ぎご連絡まで", "先简单通知您一下", "ocr", false),
        ]
        for (source, translated, origin, favorite) in samples {
            let entry = HistoryEntry(
                sourceText: source, translatedText: translated, sourceCode: "auto", targetCode: "zh-Hans",
                providerID: "anthropic", providerName: "Anthropic", model: "claude-opus-5-5",
                origin: HistoryOrigin(rawValue: origin) ?? .main
            )
            entry.isFavorite = favorite
            state.context.insert(entry)
        }
        state.context.insert(GlossaryTerm(term: "Transory", translation: "Transory"))
        state.context.insert(GlossaryTerm(term: "feature flag", translation: "功能开关"))
        try? state.context.save()
    }

    /// 画一张三行英文的示例图，用来跑一遍真实的 Vision 识别。
    private static func sampleImage() -> CGImage? {
        let size = NSSize(width: 640, height: 360)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.24, alpha: 1).setFill()
            rect.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
            "Q3 Release Notes".draw(at: NSPoint(x: 44, y: 44), withAttributes: title)
            "Offline mode for local models".draw(at: NSPoint(x: 44, y: 120), withAttributes: body)
            "Glossary sync across devices".draw(at: NSPoint(x: 44, y: 170), withAttributes: body)
            "Batch translate PDF and DOCX".draw(at: NSPoint(x: 44, y: 220), withAttributes: body)
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func save(_ window: NSWindow?, to path: String) {
        // 取 contentView 的父视图，连同标题栏一起渲染。
        guard let window, let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            print("snapshot: 找不到窗口 → \(path)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // 毛玻璃背景的列表在快照里可能画成白色，打印行数以确认内容确实存在。
        let rows = tables(in: view).map { "\(type(of: $0)):\($0.numberOfRows)" }
        print("snapshot: \(window.title) → \(path) 列表行数 \(rows)")
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? [] + view.subviews.flatMap(tables(in:))
    }
}

/// 快照用的假模型：逐行返回「示例译文 n」，不发网络请求。
struct SnapshotProvider: TranslationProvider {
    let config: ProviderConfig

    func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
        let lines = request.text.components(separatedBy: "\n")
        let text = if lines.count > 1 {
            lines.indices.map { "示例译文 \($0 + 1)" }.joined(separator: "\n")
        } else if request.text.count > 200 {
            String(repeating: "（快照模式示例译文）这是一段较长的译文，用来检查浮窗能否完整显示全部内容。", count: 8)
        } else {
            "（快照模式示例译文）\(config.name) 的译文会显示在这里。"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}
#endif
