import SwiftUI
import TransoryCore

/// 主窗口：左侧导航 + 右侧页面。
struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            List(selection: $state.navigation) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                Section("已连接模型") {
                    ForEach(state.providers(for: .main)) { config in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(state.hasAPIKey(config) ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(config.name)
                        }
                        .selectionDisabled()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                SettingsButton {
                    Label("设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            switch state.navigation ?? .translate {
            case .translate: TranslateView()
            case .history: HistoryView(favoritesOnly: false)
            case .favorites: HistoryView(favoritesOnly: true)
            case .glossary: GlossaryView()
            }
        }
        .frame(minWidth: 900, minHeight: 520)
    }
}

extension View {
    func paneStyle(background: Color = Color(nsColor: .textBackgroundColor)) -> some View {
        self
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// 模型名 + 状态（翻译中 / 耗时 / 错误）。
struct StatusLabel: View {
    let name: String?
    let phase: ComparisonUpdate.Phase?

    var body: some View {
        HStack(spacing: 6) {
            if phase == .streaming {
                ProgressView().controlSize(.mini)
            }
            Text([name, phase?.statusText].compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(phase?.isFailed == true ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}
