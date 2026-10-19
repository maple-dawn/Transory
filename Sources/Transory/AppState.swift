import AppKit
import Foundation
import Observation
import SwiftData
import SwiftUI
import TransoryCore

/// 主窗口侧栏的页面。
enum SidebarItem: String, CaseIterable, Identifiable {
    case translate, history, favorites, glossary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: "翻译"
        case .history: "历史记录"
        case .favorites: "收藏"
        case .glossary: "术语表"
        }
    }

    var systemImage: String {
        switch self {
        case .translate: "character.bubble"
        case .history: "clock"
        case .favorites: "star"
        case .glossary: "book.closed"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// nil 表示跟随系统设置。
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 可以单独选择模型的窗口。
enum WindowScope: String, CaseIterable, Identifiable, Codable {
    case popover, menubar, main

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popover: "划词浮窗"
        case .menubar: "菜单栏"
        case .main: "主窗口"
        }
    }

    var hint: String {
        switch self {
        case .popover: "划词浮窗会同时请求下面打开的服务，每个服务一张结果卡片。"
        case .menubar: "菜单栏快捷翻译只用排在第一位的服务，建议选一个响应快的。"
        case .main: "主窗口第一个服务给出主译文，其余显示在「其他模型」里对比。"
        }
    }
}

@MainActor
@Observable
final class AppState {
    private static let providersKey = "providers"
    private static let scopesKey = "scopeProviders"
    private static let legacyPrimaryKey = "primaryProviderID"

    private let keychain = KeychainStore()
    /// API Key 缓存：启动时从钥匙串读一次，之后读内存，避免界面刷新时反复访问钥匙串（可能弹出系统授权框）。
    private var apiKeys: [String: String] = [:]
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    var providers: [ProviderConfig] {
        didSet { saveProviders() }
    }

    /// 每个窗口使用的服务 id，按顺序排列，第一个是该窗口的默认服务。
    var scopeProviders: [WindowScope: [String]] {
        didSet { saveScopes() }
    }

    /// 主窗口的默认服务。设置时把它移到主窗口列表的第一位。
    var primaryProviderID: String {
        get { providers(for: .main).first?.id ?? "" }
        set { moveToFront(newValue, in: .main) }
    }

    /// 主窗口译文区当前显示的是哪个服务的结果（从历史或浮窗带过来时可能不是默认服务）。
    private(set) var displayedProviderID: String?

    /// 设置窗口当前的标签页。
    var settingsTab: SettingsTab = .general
    /// 是否显示「添加模型服务」面板。
    var isAddingProvider = false
    /// 设置 › 模型服务里选中的服务。
    var selectedServiceID: String?
    /// 设置 › 模型服务当前在配置哪个窗口。
    var settingsScope: WindowScope = .popover

    /// 打开设置并定位到某个窗口的模型服务（配合 SettingsLink 使用）。
    func showServiceSettings(for scope: WindowScope) {
        settingsTab = .services
        settingsScope = scope
    }

    var navigation: SidebarItem? = .translate

    // 主窗口的输入
    var sourceText = ""
    var source: Language = .auto
    var target: Language = .simplifiedChinese
    var style: TranslationStyle = .natural

    /// 三个场景各自的翻译状态。
    let main = TranslationSession()
    let popover = TranslationSession()
    let ocr = TranslationSession()

    /// 主窗口当前译文对应的历史记录，用于「收藏」按钮。
    private(set) var mainHistoryEntry: HistoryEntry?
    /// 浮窗当前译文对应的历史记录，用于浮窗工具栏的「收藏」。
    var popoverHistoryEntry: HistoryEntry?
    @ObservationIgnored private var mainOrigin: HistoryOrigin = .main

    /// 由菜单栏图标视图注入，用于从 AppKit 代码打开 SwiftUI 窗口。
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    init() {
        container = Store.makeContainer()
        let defaults = UserDefaults.standard
        var loaded: [ProviderConfig]
        if let data = defaults.data(forKey: Self.providersKey),
           let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data),
           !saved.isEmpty {
            loaded = saved
        } else {
            loaded = ProviderConfig.presets
        }
        // 旧版本保存的服务没有可用模型列表，用内置模板补上。
        for index in loaded.indices where loaded[index].models.isEmpty {
            loaded[index].models = ProviderTemplate.all.first { $0.id == loaded[index].id }?.models ?? []
        }
        providers = loaded

        var scopes: [WindowScope: [String]]
        if let data = defaults.data(forKey: Self.scopesKey),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            scopes = Dictionary(uniqueKeysWithValues: saved.compactMap { key, ids in
                WindowScope(rawValue: key).map { ($0, ids) }
            })
        } else {
            scopes = Self.migratedScopes(providers: loaded, primaryID: defaults.string(forKey: Self.legacyPrimaryKey))
        }
        // 去掉已删除服务的 id。
        let known = Set(loaded.map(\.id))
        scopes = scopes.mapValues { $0.filter(known.contains) }
        scopeProviders = scopes
        loadAPIKeys()

        main.onFinish = { [weak self] providerID, request, result in
            guard let self else { return }
            let recorded = self.mainOrigin == .menubar ? self.menubarProvider?.id : self.primaryProvider?.id
            guard providerID == recorded else { return }
            self.mainHistoryEntry = self.recordHistory(request: request, result: result, providerID: providerID, origin: self.mainOrigin)
        }
        popover.onFinish = { [weak self] providerID, request, result in
            // 浮窗会同时请求多个模型，只记录排在第一位的服务的结果。
            guard let self, providerID == self.providers(for: .popover).first?.id else { return }
            self.popoverHistoryEntry = self.recordHistory(request: request, result: result, providerID: providerID, origin: .popover)
        }
        ocr.onFinish = { [weak self] providerID, request, result in
            self?.recordHistory(request: request, result: result, providerID: providerID, origin: .ocr)
        }
    }

    // MARK: - 派生数据

    /// 某个窗口打开的服务，按顺序。
    func providers(for scope: WindowScope) -> [ProviderConfig] {
        (scopeProviders[scope] ?? []).compactMap(provider(id:))
    }

    func isEnabled(_ id: String, in scope: WindowScope) -> Bool {
        scopeProviders[scope]?.contains(id) == true
    }

    var primaryProvider: ProviderConfig? {
        providers(for: .main).first
    }

    var comparisonProviders: [ProviderConfig] {
        Array(providers(for: .main).dropFirst())
    }

    var menubarProvider: ProviderConfig? {
        providers(for: .menubar).first ?? primaryProvider
    }

    /// 主窗口译文区显示的服务。
    var displayedProvider: ProviderConfig? {
        displayedProviderID.flatMap(provider(id:)) ?? primaryProvider
    }

    var primaryResult: ModelResult? {
        displayedProvider.flatMap { main.results[$0.id] }
    }

    var menubarResult: ModelResult? {
        menubarProvider.flatMap { main.results[$0.id] }
    }

    func provider(id: String) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    func hasAPIKey(_ config: ProviderConfig) -> Bool {
        !config.requiresAPIKey || !apiKey(for: config.id).isEmpty
    }

    func apiKey(for id: String) -> String {
        apiKeys[id] ?? ""
    }

    func setAPIKey(_ key: String, for id: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKeys[id, default: ""] != key else { return }
        apiKeys[id] = key
        keychain.setAPIKey(key, for: id)
    }

    private func loadAPIKeys() {
        #if DEBUG
        // 快照模式不碰钥匙串：调试版签名不同，读取会弹出系统授权框。
        if SnapshotTool.isActive {
            ChatGPTSession.useInMemoryStore()
            return
        }
        #endif
        for config in providers where config.requiresAPIKey {
            apiKeys[config.id] = keychain.apiKey(for: config.id)
        }
    }

    func makeTranslator(_ config: ProviderConfig) -> any TranslationProvider {
        #if DEBUG
        if SnapshotTool.isActive { return SnapshotProvider(config: config) }
        #endif
        return ProviderFactory.make(config, apiKey: apiKey(for: config.id))
    }

    /// 组装请求：自动语言时按原文调整目标语言，并带上原文里出现的术语。
    func makeRequest(text: String, source: Language, target: Language, style: TranslationStyle) -> TranslateRequest {
        TranslateRequest(
            text: text,
            source: source,
            target: LanguageDetector.resolveTarget(for: text, source: source, target: target),
            style: style,
            glossary: glossary(for: text)
        )
    }

    // MARK: - 主窗口翻译

    func translate(origin: HistoryOrigin = .main) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let configs = origin == .menubar ? [menubarProvider].compactMap { $0 } : providers(for: .main)
        guard !text.isEmpty, !configs.isEmpty else { return }
        mainOrigin = origin
        displayedProviderID = nil
        mainHistoryEntry = nil
        main.run(makeRequest(text: text, source: source, target: target, style: style), providers: configs.map(makeTranslator))
    }

    /// 把某个对比模型设为主模型，它的结果随之成为主译文。
    func adopt(_ providerID: String) {
        primaryProviderID = providerID
    }

    func swapLanguages() {
        guard source != .auto else { return }
        (source, target) = (target, source)
        if let translated = primaryResult?.text, !translated.isEmpty {
            sourceText = translated
        }
    }

    func toggleFavorite(_ entry: HistoryEntry) {
        entry.isFavorite.toggle()
        try? context.save()
    }

    /// 在翻译页打开一条历史：填回原文和语言，并直接显示当时的译文，不重新请求。
    func open(_ entry: HistoryEntry) {
        sourceText = entry.sourceText
        source = .auto
        if let language = Language.from(code: entry.targetCode), language != .auto {
            target = language
        }
        if let shown = provider(id: entry.providerID) ?? primaryProvider {
            displayedProviderID = shown.id
            main.present(
                ModelResult(text: entry.translatedText, phase: .finished(duration: .zero)),
                providerID: shown.id,
                request: makeRequest(text: entry.sourceText, source: .auto, target: target, style: style)
            )
        }
        mainHistoryEntry = entry
        navigation = .translate
        showMainWindow()
    }

    /// 把浮窗、OCR 的内容带到主窗口：有完成的译文就直接显示，否则重新翻译。
    func presentInMain(request: TranslateRequest, result: ModelResult?, providerID: String?) {
        sourceText = request.text
        navigation = .translate
        if let result, result.phase.isFinished, let providerID, provider(id: providerID) != nil {
            displayedProviderID = providerID
            main.present(result, providerID: providerID, request: request)
            mainHistoryEntry = nil
        } else {
            translate()
        }
        showMainWindow()
    }

    /// 由 `Features` 注入：开始截图翻译。
    @ObservationIgnored var startScreenshot: (() -> Void)?
    /// 注册成功的全局快捷键 id，用于在设置里标出被占用的快捷键。
    var registeredHotKeys: Set<UInt32> = []

    /// 外观：跟随系统 / 浅色 / 深色。
    var theme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            applyTheme()
        }
    }

    /// 应用到整个 App，包括浮窗、菜单栏面板和设置窗口。
    func applyTheme() {
        NSApp.appearance = theme.appearance
    }

    /// 选中文字后是否显示翻译小按钮。
    var showSelectionButton: Bool = UserDefaults.standard.object(forKey: "showSelectionButton") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSelectionButton, forKey: "showSelectionButton") }
    }

    func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
        NSApp.activate()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 历史与术语

    @discardableResult
    private func recordHistory(request: TranslateRequest, result: ModelResult, providerID: String, origin: HistoryOrigin) -> HistoryEntry? {
        guard result.phase.isFinished, !result.text.isEmpty, let config = provider(id: providerID) else { return nil }

        var latest = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        latest.fetchLimit = 1
        let entry: HistoryEntry
        if let last = try? context.fetch(latest).first, last.sourceText == request.text {
            // 同一段原文重复翻译时更新上一条，而不是新增。
            entry = last
            entry.createdAt = .now
            entry.translatedText = result.text
            entry.targetCode = request.target.code
            entry.providerID = config.id
            entry.providerName = config.name
            entry.model = config.model
        } else {
            entry = HistoryEntry(
                sourceText: request.text,
                translatedText: result.text,
                sourceCode: request.source.code,
                targetCode: request.target.code,
                providerID: config.id,
                providerName: config.name,
                model: config.model,
                origin: origin
            )
            context.insert(entry)
        }
        try? context.save()
        return entry
    }

    /// 清空历史记录，收藏的保留。
    func clearHistory() {
        try? context.delete(model: HistoryEntry.self, where: #Predicate { !$0.isFavorite })
        try? context.save()
    }

    /// 启用的、且在原文中出现过的术语。
    func glossary(for text: String) -> [GlossaryEntry] {
        let descriptor = FetchDescriptor<GlossaryTerm>(predicate: #Predicate { $0.isEnabled })
        let terms = (try? context.fetch(descriptor)) ?? []
        return terms
            .filter { !$0.term.isEmpty && !$0.translation.isEmpty && text.localizedCaseInsensitiveContains($0.term) }
            .map { GlossaryEntry(term: $0.term, translation: $0.translation) }
    }

    // MARK: - 服务商管理

    /// 从模板添加一个服务，并在 `scope` 窗口里打开它。
    @discardableResult
    func addProvider(from template: ProviderTemplate, enableIn scope: WindowScope?) -> ProviderConfig {
        let taken = Set(providers.map(\.id))
        let id = taken.contains(template.id) ? "\(template.id)-\(UUID().uuidString.prefix(8).lowercased())" : template.id
        let config = template.makeConfig(id: id)
        providers.append(config)
        if let scope { setEnabled(true, id: id, in: scope) }
        if template.kind == .codex {
            // Codex 可能装在别处，添加后自动查找一次。
            Task {
                if let url = await CodexCLI.locate(), let index = providers.firstIndex(where: { $0.id == id }) {
                    providers[index].baseURL = url
                }
            }
        }
        return config
    }

    /// 已经添加过的模板（自定义模板可重复添加，不算在内）。
    func isAdded(_ template: ProviderTemplate) -> Bool {
        !template.isRepeatable && providers.contains { $0.id == template.id }
    }

    func removeProvider(_ id: String) {
        providers.removeAll { $0.id == id }
        scopeProviders = scopeProviders.mapValues { $0.filter { $0 != id } }
        setAPIKey("", for: id)
    }

    func setEnabled(_ enabled: Bool, id: String, in scope: WindowScope) {
        var ids = scopeProviders[scope] ?? []
        ids.removeAll { $0 == id }
        if enabled { ids.append(id) }
        scopeProviders[scope] = ids
    }

    func moveToFront(_ id: String, in scope: WindowScope) {
        guard provider(id: id) != nil else { return }
        scopeProviders[scope] = [id] + (scopeProviders[scope] ?? []).filter { $0 != id }
    }

    /// 设置页的服务列表顺序：先是该窗口打开的（按使用顺序），再是其余的。
    func orderedProviders(for scope: WindowScope) -> [ProviderConfig] {
        let enabled = providers(for: scope)
        let enabledIDs = Set(enabled.map(\.id))
        return enabled + providers.filter { !enabledIDs.contains($0.id) }
    }

    /// 拖动排序：只有打开的服务参与排序，顺序决定默认服务。
    func reorder(_ ordered: [ProviderConfig], in scope: WindowScope) {
        let enabled = Set(scopeProviders[scope] ?? [])
        scopeProviders[scope] = ordered.map(\.id).filter(enabled.contains)
    }

    /// 旧版本的设置（全局主模型 + 「参与对比」）转成按窗口的列表。
    private static func migratedScopes(providers: [ProviderConfig], primaryID: String?) -> [WindowScope: [String]] {
        let enabled = providers.filter(\.isEnabled)
        let primary = enabled.first { $0.id == primaryID } ?? enabled.first
        let comparison = enabled.filter { $0.includeInComparison && $0.id != primary?.id }.map(\.id)
        let main = (primary.map { [$0.id] } ?? []) + comparison
        return [.main: main, .popover: main, .menubar: Array(main.prefix(1))]
    }

    private func saveScopes() {
        #if DEBUG
        if SnapshotTool.isActive { return }
        #endif
        let raw = Dictionary(uniqueKeysWithValues: scopeProviders.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.scopesKey)
        }
    }

    /// 用一句短文本试翻，确认地址、Key 和模型都可用。
    func testConnection(_ config: ProviderConfig) async -> Result<String, Error> {
        let request = TranslateRequest(text: "Hello, world.", source: .english, target: .simplifiedChinese)
        do {
            return .success(try await makeTranslator(config).translateAll(request))
        } catch {
            return .failure(error)
        }
    }

    private func saveProviders() {
        #if DEBUG
        // 快照模式只改内存，不写入真实设置。
        if SnapshotTool.isActive { return }
        #endif
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: Self.providersKey)
        }
    }
}
