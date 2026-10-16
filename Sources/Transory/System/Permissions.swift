import AppKit
import ApplicationServices
import CoreGraphics

/// 划词需要「辅助功能」，截图需要「屏幕录制」。
@MainActor
enum Permissions {
    enum Kind {
        case accessibility, screenRecording

        var title: String {
            switch self {
            case .accessibility: "辅助功能"
            case .screenRecording: "屏幕录制"
            }
        }

        var purpose: String {
            switch self {
            case .accessibility: "读取其他 App 中选中的文字，以及「替换原文」"
            case .screenRecording: "截图翻译"
            }
        }

        fileprivate var settingsURL: URL {
            switch self {
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// 触发系统授权提示；已拒绝过的情况下系统不会再弹，所以同时打开系统设置。
    static func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                openSettings(kind)
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() {
                openSettings(kind)
            }
        }
    }

    static func openSettings(_ kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
