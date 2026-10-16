import AppKit
import SwiftUI
import TransoryCore

/// 菜单栏里的快捷翻译面板：只请求主模型，不做多模型对比。
struct MenuBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let result = state.menubarResult

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transory").font(.headline)
                Spacer()
                Text(state.menubarProvider?.name ?? "未选择服务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("输入要翻译的文本，回车翻译", text: $state.sourceText, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.translate(origin: .menubar) }

            if let result {
                VStack(alignment: .leading, spacing: 6) {
                    if let request = state.main.lastRequest {
                        Text("\(request.source.name) → \(request.target.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(result.text.isEmpty ? result.phase.statusText : result.text)
                        .textSelection(.enabled)
                        .foregroundStyle(result.phase.isFailed ? .red : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Button("复制") { state.copy(result.text) }
                        Button("在主窗口打开") { state.showMainWindow() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(result.text.isEmpty)
                }
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()
            VStack(spacing: 6) {
                ForEach(HotKey.all) { hotKey in
                    HStack {
                        Text(hotKey.title)
                        Spacer()
                        Text(hotKey.display)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .font(.caption)

            if !Permissions.isGranted(.accessibility) {
                Button("划词翻译需要「辅助功能」权限，点此授权") { Permissions.request(.accessibility) }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Divider()
            HStack {
                Button("截图翻译") { state.startScreenshot?() }
                Button("主窗口") { state.showMainWindow() }
                SettingsLink { Text("设置…") }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 360)
    }
}
