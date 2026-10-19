import AppKit
import SwiftUI
import TransoryCore

@main
struct TransoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let state = appDelegate.state

        WindowGroup("Transory", id: "main") {
            MainView()
                .environment(state)
        }
        .modelContainer(state.container)
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra {
            MenuBarView()
                .environment(state)
                .modelContainer(state.container)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(state)
                .modelContainer(state.container)
        }
    }
}

/// 菜单栏图标。它在 App 运行期间一直存在，借它把 `openWindow` 交给 AppKit 代码使用。
private struct MenuBarLabel: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "character.bubble")
            .onAppear { state.openWindowAction = openWindow }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) var features: Features?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用 `swift run` 启动时没有 Info.plist，要手动设成普通 App 才会出现 Dock 图标并显示窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        state.applyTheme()
        let features = Features(state: state)
        self.features = features
        #if DEBUG
        SnapshotTool.runIfRequested(state: state, features: features)
        if SnapshotTool.isActive { return }
        #endif
        // 划词需要辅助功能、截图需要屏幕录制；缺一个就引导用户去开。
        PermissionGuideController.shared.showIfNeeded()
    }
}
