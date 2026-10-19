import SwiftUI
import TransoryCore

/// 翻译页：原文 / 译文双栏 + 其他模型对比。
struct TranslateView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 16) {
            HStack(spacing: 16) {
                SourcePane()
                TargetPane()
            }
            if !state.comparisonProviders.isEmpty {
                ComparisonSection()
            }
        }
        .padding(20)
        .navigationTitle("翻译")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("源语言", selection: $state.source) {
                    ForEach(Language.sources) { Text($0.name).tag($0) }
                }
                Button {
                    state.swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("交换语言")
                .disabled(state.source == .auto)
                Picker("目标语言", selection: $state.target) {
                    ForEach(Language.targets) { Text($0.name).tag($0) }
                }
            }
            ToolbarItemGroup {
                Picker("模型", selection: $state.primaryProviderID) {
                    ForEach(state.providers) { config in
                        Text("\(config.name) · \(config.model)").tag(config.id)
                    }
                }
                Picker("风格", selection: $state.style) {
                    ForEach(TranslationStyle.allCases) { Text("风格：\($0.displayName)").tag($0) }
                }
            }
        }
    }
}

private struct SourcePane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            Text("原文 · \(state.source.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], 14)
            TextEditor(text: $state.sourceText)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            HStack {
                Button {
                    state.sourceText = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("清空")
                Spacer()
                Text("\(state.sourceText.count) 字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.main.isTranslating {
                    Button("停止") { state.main.cancel() }
                } else {
                    Button("翻译") { state.translate() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(state.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
        }
        .paneStyle()
    }
}

private struct TargetPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let result = state.primaryResult
        let target = state.main.lastRequest?.target ?? state.target

        VStack(alignment: .leading, spacing: 0) {
            Text("译文 · \(target.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], 14)
            ScrollView {
                Text(result?.text ?? "")
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    state.copy(result?.text ?? "")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制译文")
                .disabled(result?.text.isEmpty ?? true)

                Button {
                    SpeechPlayer.shared.speak(result?.text ?? "", language: target)
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .help("朗读译文")
                .disabled(result?.text.isEmpty ?? true)

                if let entry = state.mainHistoryEntry {
                    Button {
                        state.toggleFavorite(entry)
                    } label: {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    }
                    .help(entry.isFavorite ? "取消收藏" : "收藏")
                }
                Spacer()
                if let provider = state.displayedProvider {
                    StatusLabel(name: provider.model.isEmpty ? provider.name : provider.model, phase: result?.phase)
                } else {
                    Text("请先在设置中启用一个模型").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .paneStyle(background: Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

private struct ComparisonSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("其他模型").font(.headline)
                Text("点击「采用」把它设为主模型").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsButton(.services(.main)) { Text("管理对比模型") }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(state.comparisonProviders) { config in
                    ComparisonCard(config: config, result: state.main.results[config.id])
                }
            }
        }
    }
}

private struct ComparisonCard: View {
    @Environment(AppState.self) private var state
    let config: ProviderConfig
    let result: ModelResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(config.name).font(.subheadline.weight(.semibold))
                if let phase = result?.phase {
                    StatusLabel(name: nil, phase: phase)
                }
                Spacer()
                Button("采用") { state.adopt(config.id) }
                    .controlSize(.small)
                    .disabled(result == nil)
            }
            Text(result.map(\.text).flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .paneStyle()
    }
}
