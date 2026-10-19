import AppKit
import SwiftUI
import TransoryCore

/// 划词浮窗，对应设计稿「翻译浮窗 v2」：工具栏 → 可编辑原文 → 语言栏 → 每个模型一张结果卡片。
struct PopoverView: View {
    @Environment(AppState.self) private var state
    @Bindable var controller: PopoverController
    /// 工具栏以下内容的实际高度，用来决定浮窗高度。
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(controller: controller)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 8) {
                    SourceCard(controller: controller)
                    LanguageBar(controller: controller)
                    ForEach(controller.providers) { config in
                        ResultCard(controller: controller, config: config)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // 内容不超过上限时完整显示，超过才滚动。
            .frame(height: min(contentHeight, controller.maxBodyHeight))
            .scrollIndicators(contentHeight > controller.maxBodyHeight ? .automatic : .never)
        }
        .frame(width: controller.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(PopoverPalette.background)
        .onChange(of: contentHeight) { resizePanel() }
        .onChange(of: controller.width) { resizePanel() }
    }

    /// 等本轮布局结束后再调整窗口大小，避免在布局过程中改窗口。
    private func resizePanel() {
        Task { @MainActor in controller.fitToContent() }
    }
}

// MARK: - 工具栏

private struct Toolbar: View {
    @Environment(AppState.self) private var state
    let controller: PopoverController

    var body: some View {
        let favorite = controller.historyEntry?.isFavorite == true

        HStack(spacing: 2) {
            ToolButton(controller.isPinned ? "pin.fill" : "pin", help: controller.isPinned ? "取消固定" : "固定浮窗", isOn: controller.isPinned) {
                controller.isPinned.toggle()
            }
            Spacer()
            ToolButton(favorite ? "star.fill" : "star", help: favorite ? "取消收藏" : "收藏", isOn: favorite) {
                controller.toggleFavorite()
            }
            .disabled(controller.historyEntry == nil)
            ToolButton("clock", help: "历史记录") { controller.openHistory() }
            ToolButton("viewfinder", help: "截图翻译") { controller.startScreenshot() }
            ToolButton("macwindow", help: "在主窗口打开") { controller.openInMain() }
            SettingsButton {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolButtonStyle(isOn: false))
            .help("偏好设置")
            .accessibilityLabel("偏好设置")
        }
    }
}

// MARK: - 原文

private struct SourceCard: View {
    @Bindable var controller: PopoverController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("原文", text: $controller.sourceText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineSpacing(3)
                .lineLimit(1...14)
                .labelsHidden()
                .onSubmit { controller.translate() }
                .padding(.horizontal, 12)
                .padding(.top, 12)

            HStack(spacing: 2) {
                ToolButton("speaker.wave.2", help: "朗读原文", size: 13) { controller.speakSource() }
                ToolButton("doc.on.doc", help: "复制原文", size: 13) { controller.state.copy(controller.sourceText) }
                if let detected = controller.detected {
                    (Text("识别为 ") + Text(detected.name).foregroundColor(.accentColor).bold())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(PopoverPalette.chip, in: Capsule())
                        .padding(.leading, 4)
                }
                Spacer()
                Text("↩ 重新翻译")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .card()
    }
}

// MARK: - 语言栏

private struct LanguageBar: View {
    let controller: PopoverController

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(Language.sources) { language in
                    Button(language.name) { controller.setSource(language) }
                }
            } label: {
                Text(controller.source == .auto ? "自动检测" : controller.source.name)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity)

            ToolButton("arrow.left.arrow.right", help: "交换语言") { controller.swapLanguages() }

            Menu {
                ForEach(Language.targets) { language in
                    Button(language.name) { controller.setTarget(language) }
                }
            } label: {
                // 自动改了目标语言时（例如原文就是中文），显示实际使用的语言。
                Text(controller.request?.target.name ?? controller.target.name)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 13, weight: .medium))
        .frame(height: 36)
        .card()
    }
}

// MARK: - 结果卡片

private struct ResultCard: View {
    let controller: PopoverController
    let config: ProviderConfig

    var body: some View {
        let id = config.id
        let result = controller.result(for: id)
        let isCollapsed = controller.collapsed.contains(id)
        let isDefault = controller.providerIDs.first == id

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(config.name.prefix(1)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(PopoverPalette.monogram, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(config.name)
                    .font(.system(size: 13, weight: .semibold))
                if isDefault {
                    Text("默认")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(PopoverPalette.chip, in: Capsule())
                }
                if let result {
                    Text(statusText(result.phase))
                        .font(.system(size: 11))
                        .foregroundStyle(statusStyle(result.phase))
                }
                Spacer()
                ToolButton("chevron.down", help: isCollapsed ? "展开 \(config.name)" : "折叠 \(config.name)", size: 11) {
                    controller.toggleCollapsed(id)
                }
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .accessibilityValue(isCollapsed ? "已折叠" : "已展开")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { controller.toggleCollapsed(id) }

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    if let result, case .failed(let message) = result.phase {
                        ErrorRow(message: message)
                    }
                    if let result, !result.text.isEmpty {
                        (Text(result.text) + Text(result.phase == .streaming ? " ▍" : "").foregroundColor(.accentColor))
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if result?.phase == .streaming {
                        ProgressView().controlSize(.small)
                    }
                    if result?.phase.isFinished == true {
                        HStack(spacing: 2) {
                            ToolButton("speaker.wave.2", help: "朗读译文", size: 13) { controller.speak(id) }
                            ToolButton("doc.on.doc", help: "复制译文", size: 13) { controller.copy(id) }
                            ToolButton("arrow.right.to.line", help: "替换选中文字", size: 13) { controller.replace(id) }
                            Spacer()
                            if !isDefault {
                                Button("设为默认") { controller.makeDefault(id) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, -6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .card()
    }

    private func statusText(_ phase: ComparisonUpdate.Phase) -> String {
        switch phase {
        case .streaming: "翻译中…"
        case .finished: phase.statusText
        case .failed: "失败"
        }
    }

    private func statusStyle(_ phase: ComparisonUpdate.Phase) -> AnyShapeStyle {
        switch phase {
        case .streaming: AnyShapeStyle(Color.accentColor)
        case .finished: AnyShapeStyle(.secondary)
        case .failed: AnyShapeStyle(PopoverPalette.errorText)
        }
    }
}

private struct ErrorRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            SettingsButton(.services(.popover)) { Text("去设置").fontWeight(.semibold) }
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
        .foregroundStyle(PopoverPalette.errorText)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(PopoverPalette.errorBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 通用小组件

private struct ToolButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    var size: CGFloat = 14
    let action: () -> Void

    init(_ systemImage: String, help: String, isOn: Bool = false, size: CGFloat = 14, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isOn = isOn
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolButtonStyle(isOn: isOn))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ToolButtonStyle: ButtonStyle {
    let isOn: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
            )
            .onHover { hovering = $0 }
    }
}

private extension View {
    func card() -> some View {
        self
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PopoverPalette.border))
    }
}

/// 浮窗配色，浅色 / 深色各一套，跟随 App 外观自动切换。
enum PopoverPalette {
    static let background = dynamic(light: 0xF2F2F5, dark: 0x1C1C1E)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let border = dynamic(light: 0xE2E2E6, dark: 0x3A3A3F)
    static let chip = dynamic(light: 0xEEEEF1, dark: 0x38383C)
    static let monogram = dynamic(light: 0xE6E6EA, dark: 0x3F3F45)
    static let errorText = dynamic(light: 0xA3341C, dark: 0xFFB4A2)
    static let errorBackground = dynamic(light: 0xFDECE8, dark: 0x3A2724)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
