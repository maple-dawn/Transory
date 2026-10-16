import AppKit
import TransoryCore

/// 把全局快捷键与划词浮窗、截图翻译、主窗口接起来。
@MainActor
final class Features {
    let hotKeys = HotKeyCenter()
    let popover: PopoverController
    let ocr: OCRController
    let selectionButton: SelectionButtonController

    init(state: AppState) {
        popover = PopoverController(state: state)
        ocr = OCRController(state: state)
        selectionButton = SelectionButtonController(state: state, popover: popover)
        selectionButton.start()

        let popover = popover
        let ocr = ocr
        state.startScreenshot = { Task { await ocr.capture() } }

        hotKeys.register(.translateSelection) { Task { await popover.trigger() } }
        hotKeys.register(.screenshot) { Task { await ocr.capture() } }
        hotKeys.register(.mainWindow) { state.showMainWindow() }
        state.registeredHotKeys = hotKeys.registered
    }
}
