import AppKit
import SwiftUI

/// 启动时的权限引导：辅助功能（划词）和屏幕录制（截图翻译）缺一个就弹出。
@MainActor
final class PermissionGuideController {
    static let shared = PermissionGuideController()
    private static let dismissedKey = "permissionGuideDismissed"

    private var window: NSWindow?

    /// 有权限没开、且用户没有选「不再提醒」时显示。
    func showIfNeeded() {
        let missing = Permissions.Kind.allCases.contains { !Permissions.isGranted($0) }
        guard missing, !UserDefaults.standard.bool(forKey: Self.dismissedKey) else { return }
        show()
    }

    /// 从设置里手动打开时，不管「不再提醒」。
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PermissionGuideView(close: { [weak self] in self?.close() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "设置权限"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }

    var windowForSnapshot: NSWindow? { window }

    static var isDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    /// 屏幕录制授权后要重启才生效：等当前进程退出后再打开自己。
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

extension Permissions.Kind: CaseIterable {
    static var allCases: [Permissions.Kind] { [.accessibility, .screenRecording] }

    var systemImage: String {
        switch self {
        case .accessibility: "hand.point.up.left"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    /// 引导里给用户看的说明。
    var guideText: String {
        switch self {
        case .accessibility: "用于读取其他 App 中选中的文字（划词翻译、选中后的翻译按钮），以及「替换选中文字」。"
        case .screenRecording: "用于截图翻译：框选屏幕区域，识别其中的文字。授权后需要重新打开 Transory。"
        }
    }
}

struct PermissionGuideView: View {
    let close: () -> Void

    @State private var granted: [Permissions.Kind: Bool] = [:]
    /// 启动时屏幕录制是否已授权；之后才授权的需要重启才生效。
    @State private var screenRecordingAtLaunch = Permissions.isGranted(.screenRecording)
    @State private var dontRemind = PermissionGuideController.isDismissed
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allGranted: Bool {
        Permissions.Kind.allCases.allSatisfy { granted[$0] == true }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text(allGranted ? "权限都已开启" : "开启权限，让 Transory 更好用")
                    .font(.title2.weight(.semibold))
                Text(allGranted
                     ? "划词翻译和截图翻译都可以使用了。"
                     : "下面两项权限都在「系统设置 › 隐私与安全性」里开启。不开启也能在主窗口翻译，但划词和截图功能用不了。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(Permissions.Kind.allCases, id: \.self) { kind in
                    PermissionRow(
                        kind: kind,
                        isGranted: granted[kind] == true,
                        needsRelaunch: kind == .screenRecording && granted[kind] == true && !screenRecordingAtLaunch
                    )
                }
            }

            Text("如果列表里已经有 Transory 但仍显示未授权（例如更新过 App），请在系统设置里先把它移除，再重新添加或打开开关。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Toggle("启动时不再提醒", isOn: $dontRemind)
                    .toggleStyle(.checkbox)
                    .onChange(of: dontRemind) { _, value in PermissionGuideController.isDismissed = value }
                Spacer()
                if allGranted {
                    Button("开始使用", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后", action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        var next: [Permissions.Kind: Bool] = [:]
        for kind in Permissions.Kind.allCases { next[kind] = Permissions.isGranted(kind) }
        if next != granted { granted = next }
    }
}

private struct PermissionRow: View {
    let kind: Permissions.Kind
    let isGranted: Bool
    let needsRelaunch: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(isGranted ? Color.green : Color.accentColor)
                .frame(width: 36, height: 36)
                .background((isGranted ? Color.green : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).fontWeight(.semibold)
                Text(kind.guideText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Group {
                if needsRelaunch {
                    Button("重新打开") { PermissionGuideController.relaunch() }
                        .buttonStyle(.borderedProminent)
                } else if isGranted {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Button("去授权") { Permissions.request(kind) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
