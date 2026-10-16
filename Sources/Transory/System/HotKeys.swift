import Carbon.HIToolbox
import Foundation

/// 一个全局快捷键。
struct HotKey: Identifiable, Hashable {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
    let title: String

    static let translateSelection = HotKey(id: 1, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey), display: "⌥ D", title: "划词翻译")
    static let screenshot = HotKey(id: 2, keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey), display: "⌥ S", title: "截图翻译")
    static let mainWindow = HotKey(id: 3, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥ Space", title: "打开主窗口")

    static let all: [HotKey] = [.translateSelection, .screenshot, .mainWindow]
}

/// 用 Carbon 的 `RegisterEventHotKey` 注册全局快捷键，不需要辅助功能权限。
@MainActor
final class HotKeyCenter {
    private static let signature: OSType = 0x5452_5359 // "TRSY"

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    /// 已成功注册的快捷键 id；注册失败通常是被其他 App 占用。
    private(set) var registered: Set<UInt32> = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                MainActor.assumeIsolated { center.actions[id]?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    @discardableResult
    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> Bool {
        actions[hotKey.id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            EventHotKeyID(signature: Self.signature, id: hotKey.id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        refs[hotKey.id] = ref
        registered.insert(hotKey.id)
        return true
    }
}
