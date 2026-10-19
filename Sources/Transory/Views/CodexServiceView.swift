import AppKit
import SwiftUI
import TransoryCore

/// 「ChatGPT 账户」服务的配置页，两种接入方式：
/// - 内置：Transory 自己在浏览器里完成 OAuth 登录，令牌存在钥匙串，直接调用 ChatGPT 的 Codex 后端；
/// - 本机 Codex CLI：登录与凭证由 Codex 管理，Transory 只调用 `codex login` / `codex logout` / `codex exec`。
struct CodexServiceView: View {
    @Environment(AppState.self) private var state
    @Binding var config: ProviderConfig

    enum Phase: Equatable {
        case checking, notInstalled, signedOut, waiting, signedIn, apiKey
        case failed(String)
    }

    @State private var phase: Phase = .checking
    @State private var pathText = ""
    @State private var loginSession: CodexCLI.LoginSession?
    @State private var loginFlow: ChatGPTLoginFlow?
    @State private var account: ChatGPTTokens?
    @State private var loginURL: URL?
    @State private var isFetchingModels = false
    @State private var modelMessage: String?
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testFailed = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ProviderMonogram(name: config.name, id: config.id, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name).font(.title3.weight(.semibold))
                        Text("使用 ChatGPT 订阅额度翻译，无需 API Key").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(statusText, systemImage: "circle.fill")
                        .labelStyle(StatusLabelStyle())
                        .foregroundStyle(statusColor)
                        .font(.caption)
                }
            }

            Section("账户") { accountSection }

            Section("高级设置") {
                Picker("接入方式", selection: $config.codexAccess) {
                    ForEach(CodexAccess.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: config.codexAccess) {
                    cancelLogin()
                    Task { await refresh() }
                }
                if isCLI {
                    LabeledContent("Codex 路径") {
                        HStack(spacing: 6) {
                            TextField("Codex 路径", text: $pathText)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .font(.system(.caption, design: .monospaced))
                                .onSubmit(applyPath)
                            Button("自动查找") { Task { await locate() } }
                        }
                    }
                }
                LabeledContent("模型") {
                    HStack(spacing: 6) {
                        if isFetchingModels { ProgressView().controlSize(.small) }
                        Picker("模型", selection: $config.model) {
                            if isCLI { Text("默认（跟随 Codex）").tag("") }
                            if !isCLI && config.model.isEmpty { Text("请选择").tag("") }
                            ForEach(config.modelChoices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            Task { await fetchModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("刷新模型列表")
                        .disabled(phase != .signedIn || isFetchingModels)
                    }
                }
                if let modelMessage {
                    Text(modelMessage).font(.caption).foregroundStyle(.secondary)
                }
                Picker("思考程度", selection: Binding(
                    get: { config.reasoningEffort ?? "" },
                    set: { config.reasoningEffort = $0.isEmpty ? nil : $0 }
                )) {
                    Text("默认（使用模型设置）").tag("")
                    Text("低（更快）").tag("low")
                    Text("中").tag("medium")
                    Text("高（更准）").tag("high")
                }
            }

            Section("生成") {
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
                        Text(footerHint).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button("验证") { Task { await test() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(phase != .signedIn || isTesting)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            pathText = config.baseURL.path
            await refresh()
        }
        .onDisappear { cancelLogin() }
    }

    // MARK: - 账户卡片

    @ViewBuilder private var accountSection: some View {
        switch phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查 Codex 登录状态…").foregroundStyle(.secondary)
            }

        case .notInstalled:
            VStack(alignment: .leading, spacing: 10) {
                Text("没有找到 Codex CLI。Transory 通过 Codex 使用你的 ChatGPT 账户，请先在终端安装：")
                    .font(.callout)
                HStack {
                    Text(CodexCLI.installCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("复制") { state.copy(CodexCLI.installCommand) }
                }
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text("已经安装在别处？在下面的「Codex 路径」里填写，或点「重新检测」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新检测") { Task { await locate() } }
                }
            }

        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                Text(isCLI
                     ? "点击后由 Codex 在浏览器中打开 OpenAI 的登录页面。授权完成后自动回到这里；登录凭证由 Codex 保存在本机，Transory 看不到你的密码。"
                     : "点击后会在浏览器中打开 OpenAI 的登录页面。授权完成后自动回到这里；登录令牌只保存在本机钥匙串中，Transory 看不到你的密码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("尚未登录").fontWeight(.medium)
                    Spacer()
                    Button {
                        startLogin()
                    } label: {
                        Label("使用 ChatGPT 登录", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .waiting:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在等待浏览器授权…").fontWeight(.semibold)
                        Text("已在默认浏览器中打开 OpenAI 登录页面。登录并点击「允许」后，这里会自动更新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 在浏览器中登录 ChatGPT 账户")
                    Text("2. 确认授权")
                    Text("3. 看到登录成功的页面后回到 Transory")
                }
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("重新打开浏览器") { if let loginURL { NSWorkspace.shared.open(loginURL) } }
                        .disabled(loginURL == nil)
                    Button("复制登录链接") { if let loginURL { state.copy(loginURL.absoluteString) } }
                        .disabled(loginURL == nil)
                    Spacer()
                    Button("取消") { cancelLogin() }
                }
            }

        case .signedIn:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isCLI ? "已通过 ChatGPT 账户登录 Codex" : (account?.email ?? "已登录 ChatGPT")).fontWeight(.semibold)
                        Text(isCLI ? "登录凭证由 Codex 保存在本机，过期后由 Codex 自动刷新" : "已登录 · 令牌保存在钥匙串，过期前自动刷新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isCLI, let plan = account?.plan {
                        Text(plan.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                HStack {
                    Button("刷新状态") { Task { await refresh() } }
                    Spacer()
                    Button("退出登录", role: .destructive) { Task { await logout() } }
                }
            }

        case .apiKey:
            VStack(alignment: .leading, spacing: 10) {
                Text("Codex 当前使用 API Key 登录，翻译会按 API 用量计费，不使用 ChatGPT 订阅额度。如需改用 ChatGPT 账户，请先退出登录再重新登录。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("刷新状态") { Task { await refresh() } }
                    Spacer()
                    Button("退出登录", role: .destructive) { Task { await logout() } }
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("重试") { Task { await refresh() } }
                }
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .checking: "检查中"
        case .notInstalled: "未安装 Codex"
        case .signedOut: "未登录"
        case .waiting: "等待授权"
        case .signedIn: "已登录"
        case .apiKey: "API Key 模式"
        case .failed: "出错"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .signedIn, .apiKey: .green
        case .waiting, .checking: .blue
        default: .orange
        }
    }

    private var footerHint: String {
        switch phase {
        case .signedIn: isCLI ? "翻译消耗的是 ChatGPT 订阅额度；Codex 一次返回整段译文。" : "翻译消耗的是 ChatGPT 订阅额度。"
        case .waiting: "在浏览器中完成授权后会自动继续。"
        default: "登录后才能选择模型和验证。"
        }
    }

    // MARK: - 操作

    private var isCLI: Bool { config.codexAccess == .cli }

    private var chatGPTSession: ChatGPTSession { .shared(for: config.id) }

    private func refresh() async {
        if loginSession == nil && loginFlow == nil { phase = .checking }
        if !isCLI {
            account = await chatGPTSession.tokens()
            phase = account == nil ? .signedOut : .signedIn
            if account != nil && config.models.isEmpty { await fetchModels() }
            return
        }
        switch await CodexCLI.status(executable: config.baseURL) {
        case .chatGPT:
            phase = .signedIn
            if config.models.isEmpty { await fetchModels() }
        case .apiKey: phase = .apiKey
        case .signedOut: phase = .signedOut
        case .notInstalled: phase = .notInstalled
        case .failed(let message): phase = .failed(message)
        }
    }

    private func locate() async {
        phase = .checking
        if let url = await CodexCLI.locate() {
            config.baseURL = url
            pathText = url.path
        }
        await refresh()
    }

    private func applyPath() {
        let path = (pathText.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        config.baseURL = URL(fileURLWithPath: path)
        Task { await refresh() }
    }

    private func startLogin() {
        isCLI ? startCLILogin() : startBuiltInLogin()
    }

    /// 内置登录：本地回调服务 + 浏览器授权，令牌存进钥匙串。
    private func startBuiltInLogin() {
        let flow = ChatGPTLoginFlow(session: chatGPTSession)
        loginFlow = flow
        loginURL = nil
        phase = .waiting
        Task {
            do {
                let (url, wait) = try await flow.start()
                loginURL = url
                NSWorkspace.shared.open(url)
                let tokens = try await wait()
                guard loginFlow === flow else { return }
                loginFlow = nil
                account = tokens
                phase = .signedIn
                await fetchModels()
            } catch is CancellationError {
                return
            } catch {
                guard loginFlow === flow else { return }
                loginFlow = nil
                phase = .failed("登录没有完成：\(error.localizedDescription)")
            }
        }
    }

    /// Codex CLI 登录：由 `codex login` 打开浏览器并保存凭证。
    private func startCLILogin() {
        let session = CodexCLI.LoginSession(executable: config.baseURL)
        loginSession = session
        loginURL = nil
        phase = .waiting
        Task {
            let succeeded = await session.run { url in
                Task { @MainActor in loginURL = url }
            }
            guard loginSession === session else { return }
            loginSession = nil
            if succeeded {
                await refresh()
            } else if phase == .waiting {
                phase = .failed("登录没有完成。可以重试，或在终端运行 codex login 查看详情。")
            }
        }
    }

    private func cancelLogin() {
        loginSession?.cancel()
        loginSession = nil
        loginFlow?.cancel()
        loginFlow = nil
        if phase == .waiting { phase = .signedOut }
    }

    private func logout() async {
        if !isCLI {
            await chatGPTSession.signOut()
            account = nil
            phase = .signedOut
            return
        }
        do {
            try await CodexCLI.logout(executable: config.baseURL)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await refresh()
    }

    private func fetchModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            let models = try await ModelLister.fetch(config, apiKey: "")
            config.models = models
            if !config.model.isEmpty && !models.contains(config.model) { config.model = "" }
            // 内置方式必须指定模型，默认选列表里的第一个。
            if !isCLI && config.model.isEmpty { config.model = models.first ?? "" }
            modelMessage = models.isEmpty ? "Codex 没有列出可用模型" : nil
        } catch {
            modelMessage = error.localizedDescription
        }
    }

    private func test() async {
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
            testResult = "可以使用 · \(elapsed.formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1))))：\(text)"
        case .failure(let error):
            testFailed = true
            testResult = error.localizedDescription
        }
    }
}
