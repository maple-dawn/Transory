import SwiftUI
import TransoryCore

/// 截图翻译窗口，对应设计稿 Ocr.dc.html。
struct OCRView: View {
    @Environment(AppState.self) private var state
    @Bindable var controller: OCRController

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                imageArea
                Divider()
                ResultPanel(controller: controller)
                    .frame(width: 360)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Picker("显示方式", selection: $controller.mode) {
                ForEach(OCRController.DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(controller.translatedLines == nil)
            .help(controller.translatedLines == nil ? "译文完成且与原文逐行对应时才能覆盖原图" : "")

            Spacer()
            Text("识别：Apple Vision（本地）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("模型", selection: Binding(
                get: { controller.providerID ?? "" },
                set: { controller.select($0) }
            )) {
                ForEach(state.providers) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                Task { await controller.capture() }
            } label: {
                Label("重新截图 ⌥S", systemImage: "viewfinder")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var imageArea: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: .underPageBackgroundColor)
            if let image = controller.image {
                CapturedImageView(
                    image: image,
                    lines: controller.lines,
                    translatedLines: controller.mode == .overlay ? controller.translatedLines : nil,
                    outlined: controller.mode == .sideBySide
                )
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(controller.isRecognizing
                     ? "正在识别…"
                     : "\(image.width) × \(image.height) · 识别到 \(controller.lines.count) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ContentUnavailableView("按 ⌥S 截图", systemImage: "viewfinder", description: Text("框选屏幕上的区域，识别其中文字并翻译。"))
            }
        }
    }
}

/// 截图 + 文字块标注。`translatedLines` 不为空时在原位置覆盖译文。
struct CapturedImageView: View {
    let image: CGImage
    let lines: [RecognizedLine]
    let translatedLines: [String]?
    let outlined: Bool

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ForEach(lines) { line in
                        let rect = CGRect(
                            x: line.boundingBox.minX * geometry.size.width,
                            y: line.boundingBox.minY * geometry.size.height,
                            width: line.boundingBox.width * geometry.size.width,
                            height: line.boundingBox.height * geometry.size.height
                        ).insetBy(dx: -3, dy: -2)

                        if let translatedLines, line.id < translatedLines.count {
                            Text(translatedLines[line.id])
                                .font(.system(size: max(rect.height * 0.78, 6)))
                                .minimumScaleFactor(0.3)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .frame(width: rect.width, height: rect.height, alignment: .leading)
                                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 3))
                                .position(x: rect.midX, y: rect.midY)
                        } else if outlined {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.12))
                                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

private struct ResultPanel: View {
    @Environment(AppState.self) private var state
    @Bindable var controller: OCRController

    var body: some View {
        let result = controller.result
        let target = controller.session.lastRequest?.target ?? state.target

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("识别文字")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.isEdited && !controller.recognizedText.isEmpty {
                    Button("用修改后的文字重译") { controller.translate() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding([.horizontal, .top], 16)

            TextEditor(text: $controller.recognizedText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(height: 150)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Divider()

            Text("译文 · \(target.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], 16)
            ScrollView {
                Group {
                    if let error = controller.errorMessage {
                        Text(error).foregroundStyle(.secondary)
                    } else if let result, result.phase.isFailed {
                        Text(result.phase.statusText).foregroundStyle(.red)
                    } else {
                        Text(result?.text ?? "")
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            Divider()
            HStack(spacing: 6) {
                Button {
                    controller.copy()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制译文")
                if let result {
                    StatusLabel(name: nil, phase: result.phase)
                }
                Spacer()
                Button("存为图片") { controller.saveImage() }
                    .disabled(controller.image == nil)
                Button("发送到主窗口") { controller.sendToMain() }
                    .disabled(controller.session.lastRequest == nil)
            }
            .padding(10)
        }
    }
}
