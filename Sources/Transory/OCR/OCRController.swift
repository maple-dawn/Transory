import AppKit
import ImageIO
import Observation
import SwiftUI
import TransoryCore
import UniformTypeIdentifiers

/// 截图翻译：系统框选截图 → Vision 本地识别 → 翻译 → 并排或覆盖原图显示。
@MainActor
@Observable
final class OCRController {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case sideBySide, overlay
        var id: String { rawValue }
        var title: String { self == .sideBySide ? "并排" : "覆盖原图" }
    }

    let state: AppState
    private(set) var image: CGImage?
    private(set) var lines: [RecognizedLine] = []
    private(set) var isRecognizing = false
    private(set) var errorMessage: String?
    private(set) var providerID: String?
    /// 识别出的文字，可编辑后重译。
    var recognizedText = ""
    var mode: DisplayMode = .sideBySide

    @ObservationIgnored private var window: NSWindow?

    var session: TranslationSession { state.ocr }

    var result: ModelResult? {
        providerID.flatMap { session.results[$0] }
    }

    /// 能与原图逐行对应的译文；文字被编辑过或行数对不上时为 nil。
    var translatedLines: [String]? {
        guard let result, result.phase.isFinished,
              session.lastRequest?.text == LineMapper.join(lines)
        else { return nil }
        return LineMapper.split(result.text, matching: lines)
    }

    var isEdited: Bool {
        recognizedText != LineMapper.join(lines)
    }

    init(state: AppState) {
        self.state = state
    }

    // MARK: - 截图与识别

    func capture() async {
        guard Permissions.isGranted(.screenRecording) else {
            Permissions.request(.screenRecording)
            return
        }
        let url = URL.temporaryDirectory.appending(path: "transory-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
        }

        // 用户按 Esc 取消时不会生成文件。
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        await load(image)
    }

    func load(_ image: CGImage) async {
        self.image = image
        lines = []
        recognizedText = ""
        errorMessage = nil
        session.reset()
        mode = .sideBySide
        showWindow()

        isRecognizing = true
        defer { isRecognizing = false }
        do {
            lines = try await TextRecognizer.recognize(image)
        } catch {
            errorMessage = "识别失败：\(error.localizedDescription)"
            return
        }
        recognizedText = LineMapper.join(lines)
        guard !lines.isEmpty else {
            errorMessage = "没有识别到文字"
            return
        }
        translate()
    }

    // MARK: - 翻译

    func translate() {
        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerID.flatMap(state.provider(id:)) == nil {
            providerID = state.primaryProvider?.id
        }
        guard !text.isEmpty, let providerID, let config = state.provider(id: providerID) else { return }
        // 未编辑时保持原样拼接，译文才能按行对回原图。
        let requestText = isEdited ? text : LineMapper.join(lines)
        let request = state.makeRequest(text: requestText, source: .auto, target: state.target, style: state.style)
        session.run(request, providers: [state.makeTranslator(config)])
    }

    func select(_ id: String) {
        providerID = id
        translate()
    }

    func copy() {
        if let text = result?.text, !text.isEmpty { state.copy(text) }
    }

    func sendToMain() {
        guard let request = session.lastRequest else { return }
        state.presentInMain(request: request, result: result, providerID: providerID)
    }

    /// 把当前显示（含覆盖的译文）存成 PNG。
    func saveImage() {
        guard let image else { return }
        let content = CapturedImageView(image: image, lines: lines, translatedLines: mode == .overlay ? translatedLines : nil, outlined: false)
            .frame(width: CGFloat(image.width), height: CGFloat(image.height))
        let renderer = ImageRenderer(content: content)
        guard let rendered = renderer.cgImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Transory 截图翻译.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, rendered, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - 窗口

    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: OCRView(controller: self).environment(state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "截图翻译"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1100, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("OCRWindow")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var windowForSnapshot: NSWindow? { window }
}
