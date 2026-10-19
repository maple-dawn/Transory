import SwiftUI
import TransoryCore

/// 设置 › 模型服务：左边选窗口和服务（开关决定该窗口用不用），右边是所选服务的配置。
struct ServicesSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var state = state
        let scope = state.settingsScope
        let ordered = state.orderedProviders(for: scope)
        let selectedID = state.selectedServiceID

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("为哪个窗口配置", selection: $state.settingsScope) {
                    ForEach(WindowScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(scope.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                List(selection: $state.selectedServiceID) {
                    ForEach(ordered) { config in
                        ServiceRow(config: config, scope: scope)
                            .tag(config.id)
                    }
                    .onMove { from, to in
                        var list = ordered
                        list.move(fromOffsets: from, toOffset: to)
                        state.reorder(list, in: scope)
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

                HStack(spacing: 4) {
                    Button {
                        state.isAddingProvider = true
                    } label: {
                        Image(systemName: "plus").frame(width: 20, height: 16)
                    }
                    .help("添加服务")
                    Button {
                        confirmRemove = true
                    } label: {
                        Image(systemName: "minus").frame(width: 20, height: 16)
                    }
                    .help("移除所选服务")
                    .disabled(selectedID == nil)
                    Spacer()
                    Text("拖动排序 · 第一个为默认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 300)

            Divider()

            if let id = selectedID, let binding = binding(for: id) {
                if binding.wrappedValue.kind == .codex {
                    CodexServiceView(config: binding)
                        .id(id)
                } else {
                    ServiceDetailView(config: binding)
                        .id(id)
                }
            } else {
                ContentUnavailableView("选择一个服务", systemImage: "cpu", description: Text("或点左下角的 + 添加。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $state.isAddingProvider) {
            AddProviderSheet(scope: scope) { state.selectedServiceID = $0 }
                .environment(state)
        }
        .confirmationDialog(
            "移除「\(selectedID.flatMap(state.provider(id:))?.name ?? "")」？",
            isPresented: $confirmRemove
        ) {
            Button("移除", role: .destructive) {
                if let id = selectedID {
                    state.removeProvider(id)
                    state.selectedServiceID = state.orderedProviders(for: scope).first?.id
                }
            }
        } message: {
            Text("它的 API Key 也会从钥匙串中删除。")
        }
        .onAppear { state.selectedServiceID = state.selectedServiceID ?? ordered.first?.id }
    }

    private func binding(for id: String) -> Binding<ProviderConfig>? {
        guard state.provider(id: id) != nil else { return nil }
        return Binding(
            get: { state.provider(id: id) ?? ProviderConfig.anthropic },
            set: { newValue in
                if let index = state.providers.firstIndex(where: { $0.id == id }) {
                    state.providers[index] = newValue
                }
            }
        )
    }
}

/// 服务列表的一行：图标、名称、状态标记、在当前窗口是否使用的开关。
private struct ServiceRow: View {
    @Environment(AppState.self) private var state
    let config: ProviderConfig
    let scope: WindowScope

    var body: some View {
        HStack(spacing: 8) {
            ProviderMonogram(name: config.name, id: config.id, size: 22)
            Text(config.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            badge
            Toggle(
                "在\(scope.title)中使用 \(config.name)",
                isOn: Binding(
                    get: { state.isEnabled(config.id, in: scope) },
                    set: { state.setEnabled($0, id: config.id, in: scope) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badge: some View {
        if config.kind == .codex {
            Badge(text: "账户", color: .blue)
        } else if !config.requiresAPIKey {
            Badge(text: "本地", color: .green)
        } else if !state.hasAPIKey(config) {
            Badge(text: "缺 Key", color: .orange)
        } else if config.model.isEmpty {
            Badge(text: "未选模型", color: .orange)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 所选服务的配置：连接、可用模型、生成参数、验证。
private struct ServiceDetailView: View {
    @Environment(AppState.self) private var state
    @Binding var config: ProviderConfig

    @State private var apiKey = ""
    @State private var showKey = false
    @State private var baseURLText = ""
    @State private var isFetching = false
    @State private var fetchMessage: String?
    @State private var fetchFailed = false
    @State private var isAddingModel = false
    @State private var newModel = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testFailed = false

    private var isConfigured: Bool {
        (!config.requiresAPIKey || !apiKey.isEmpty) && !config.model.isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ProviderMonogram(name: config.name, id: config.id, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name).font(.title3.weight(.semibold))
                        Text(protocolDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(isConfigured ? "已配置" : (apiKey.isEmpty && config.requiresAPIKey ? "缺少 API Key" : "未选择模型"),
                          systemImage: "circle.fill")
                        .labelStyle(StatusLabelStyle())
                        .foregroundStyle(isConfigured ? .green : .orange)
                        .font(.caption)
                }
            }

            Section("连接") {
                if config.requiresAPIKey {
                    LabeledContent("API Key") {
                        HStack(spacing: 6) {
                            Group {
                                if showKey {
                                    TextField("API Key", text: $apiKey, prompt: Text("粘贴 API Key"))
                                } else {
                                    SecureField("API Key", text: $apiKey, prompt: Text("粘贴 API Key"))
                                }
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: apiKey) { saveKey() }
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showKey ? "隐藏 API Key" : "显示 API Key")
                        }
                    }
                }
                TextField("接口地址", text: $baseURLText)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: baseURLText) { _, text in
                        if let url = URL(string: text), url.scheme != nil, url.host() != nil {
                            config.baseURL = url
                        }
                    }
                TextField("名称", text: $config.name)
                    .multilineTextAlignment(.trailing)
                Picker("接口类型", selection: $config.kind) {
                    ForEach(ProviderKind.allCases.filter { $0 != .codex }) { Text($0.displayName).tag($0) }
                }
            }

            Section("可用模型") {
                VStack(alignment: .leading, spacing: 8) {
                    if config.models.isEmpty {
                        Text("还没有模型。填好 API Key 后点「从服务商获取」，或直接手动添加模型名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(config.models, id: \.self) { model in
                                ModelChip(name: model, isCurrent: model == config.model) {
                                    config.models.removeAll { $0 == model }
                                    if config.model == model { config.model = config.models.first ?? "" }
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        if let fetchMessage {
                            Text(fetchMessage)
                                .font(.caption)
                                .foregroundStyle(fetchFailed ? .red : .secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if isFetching { ProgressView().controlSize(.small) }
                        Button("手动添加") { isAddingModel = true }
                        Button("从服务商获取") { Task { await fetchModels() } }
                            .disabled(isFetching)
                    }
                }
                if config.modelChoices.isEmpty {
                    TextField("使用模型", text: $config.model, prompt: Text("填写模型名"))
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Picker("使用模型", selection: $config.model) {
                        ForEach(config.modelChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section("生成") {
                if config.kind == .anthropic {
                    LabeledContent("温度", value: "该服务的当前模型不支持自定义温度")
                } else {
                    LabeledContent("温度") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { config.temperature ?? 0.3 },
                                set: { config.temperature = ($0 * 10).rounded() / 10 }
                            ), in: 0...2)
                            .frame(maxWidth: 260)
                            Text((config.temperature ?? 0.3).formatted(.number.precision(.fractionLength(1))))
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
                Toggle("隐藏思考过程（<think> 标签）", isOn: $config.hidesThinking)
                Toggle(isOn: Binding(
                    get: { config.promptTemplate != nil },
                    set: { config.promptTemplate = $0 ? PromptBuilder.defaultTemplate : nil }
                )) {
                    Text("使用自定义提示词")
                    Text("关闭时使用内置的翻译提示词。可用变量：{source_lang} {target_lang} {style} {glossary}")
                }
                if config.promptTemplate != nil {
                    TextEditor(text: Binding(
                        get: { config.promptTemplate ?? "" },
                        set: { config.promptTemplate = $0 }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 110)
                }
            }

            Section {
                HStack(spacing: 10) {
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testFailed ? .red : .green)
                            .lineLimit(2)
                    } else {
                        Text("API Key 只保存在本机钥匙串中。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button("验证") { Task { await test() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTesting)
                }
            }
        }
        .formStyle(.grouped)
        .alert("添加模型", isPresented: $isAddingModel) {
            TextField("模型名", text: $newModel)
            Button("添加") { addModel() }
            Button("取消", role: .cancel) { newModel = "" }
        } message: {
            Text("输入服务商文档里的模型名。")
        }
        .onAppear {
            apiKey = state.apiKey(for: config.id)
            baseURLText = config.baseURL.absoluteString
        }
    }

    private var protocolDescription: String {
        if !config.requiresAPIKey { return "本地模型 · 无需 Key · 离线可用" }
        switch config.kind {
        case .openAICompatible: return "OpenAI 兼容接口"
        case .anthropic: return "Anthropic Messages API"
        case .gemini: return "Gemini API"
        case .codex: return "通过 Codex CLI 使用 ChatGPT 账户"
        }
    }

    private func saveKey() {
        state.setAPIKey(apiKey, for: config.id)
    }

    private func addModel() {
        let name = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        newModel = ""
        guard !name.isEmpty else { return }
        if !config.models.contains(name) { config.models.append(name) }
        if config.model.isEmpty { config.model = name }
    }

    private func fetchModels() async {
        saveKey()
        isFetching = true
        fetchMessage = nil
        defer { isFetching = false }
        do {
            let models = try await ModelLister.fetch(config, apiKey: state.apiKey(for: config.id))
            config.models = models
            if config.model.isEmpty || !models.contains(config.model) {
                config.model = models.first ?? config.model
            }
            fetchFailed = false
            fetchMessage = models.isEmpty ? "服务商没有返回模型" : "获取到 \(models.count) 个模型"
        } catch {
            fetchFailed = true
            fetchMessage = error.localizedDescription
        }
    }

    private func test() async {
        saveKey()
        isTesting = true
        testResult = nil
        let clock = ContinuousClock()
        let start = clock.now
        let result = await state.testConnection(config)
        let elapsed = clock.now - start
        isTesting = false
        switch result {
        case .success(let text):
            testFailed = false
            testResult = "连接正常 · \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow)))：\(text)"
        case .failure(let error):
            testFailed = true
            testResult = error.localizedDescription
        }
    }
}

private struct ModelChip: View {
    let name: String
    let isCurrent: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .fontWeight(isCurrent ? .semibold : .regular)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("移除 \(name)")
            .accessibilityLabel("移除 \(name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

/// 服务图标：名称首字母 + 由 id 决定的固定底色。
struct ProviderMonogram: View {
    let name: String
    let id: String
    let size: CGFloat

    private static let palette: [Color] = [
        Color(red: 0.71, green: 0.39, blue: 0.25), Color(red: 0.18, green: 0.49, blue: 0.42),
        Color(red: 0.23, green: 0.39, blue: 0.79), Color(red: 0.25, green: 0.33, blue: 0.78),
        Color(red: 0.35, green: 0.31, blue: 0.81), Color(red: 0.42, green: 0.25, blue: 0.79),
        Color(red: 0.17, green: 0.36, blue: 0.85), Color(red: 0.29, green: 0.29, blue: 0.56),
        Color(red: 0.32, green: 0.32, blue: 0.35),
    ]

    var body: some View {
        let index = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.palette.count
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.palette[index], in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// 按行排布、放不下就换行的布局（用于模型标签）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
