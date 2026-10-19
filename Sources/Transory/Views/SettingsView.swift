import AppKit
import SwiftUI
import TransoryCore

enum SettingsTab: Hashable {
    case general, services
}

/// 打开设置并定位到指定页面：「设置」入口打开通用页，「管理对比模型」等打开对应窗口的模型服务。
/// 不能用 SettingsLink：它会吞掉点击，附加的手势不会执行，页面也就切不过去，只会停在上次关闭时的页面。
struct SettingsButton<Label: View>: View {
    enum Destination {
        case general
        case services(WindowScope)
    }

    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    let destination: Destination
    @ViewBuilder let label: () -> Label

    init(_ destination: Destination = .general, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        Button {
            switch destination {
            case .general: state.settingsTab = .general
            case .services(let scope): state.showServiceSettings(for: scope)
            }
            openSettings()
            NSApp.activate()
        } label: {
            label()
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        TabView(selection: $state.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ServicesSettingsView()
                .tabItem { Label("模型服务", systemImage: "cpu") }
                .tag(SettingsTab.services)
        }
        .frame(width: 960, height: 680)
    }
}

/// 快捷键、权限、默认语言。
private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var granted: [Permissions.Kind: Bool] = [:]
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var state = state

        Form {
            Section("外观") {
                Picker("主题", selection: $state.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("划词翻译") {
                Toggle(isOn: $state.showSelectionButton) {
                    Text("选中文字后显示翻译按钮")
                    Text("在其他 App 里拖选或双击文字后，鼠标旁出现小按钮，点击即可翻译。需要「辅助功能」权限。")
                }
            }

            Section("快捷键") {
                ForEach(HotKey.all) { hotKey in
                    LabeledContent(hotKey.title) {
                        HStack(spacing: 8) {
                            if !state.registeredHotKeys.contains(hotKey.id) {
                                Text("已被其他 App 占用").foregroundStyle(.red)
                            }
                            Text(hotKey.display).font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }

            Section {
                ForEach([Permissions.Kind.accessibility, .screenRecording], id: \.self) { kind in
                    LabeledContent {
                        if granted[kind] == true {
                            Label("已授权", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("去授权") { Permissions.request(kind) }
                        }
                    } label: {
                        Text(kind.title)
                        Text(kind.purpose)
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("授予「屏幕录制」后需要重新打开 Transory 才会生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("翻译") {
                Picker("默认目标语言", selection: $state.target) {
                    ForEach(Language.targets) { Text($0.name).tag($0) }
                }
                Picker("默认风格", selection: $state.style) {
                    ForEach(TranslationStyle.allCases) { Text($0.displayName).tag($0) }
                }
                Text("原文与目标语言相同时（例如划选了一段中文），会自动改译成英语。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        granted = [
            .accessibility: Permissions.isGranted(.accessibility),
            .screenRecording: Permissions.isGranted(.screenRecording),
        ]
    }
}
