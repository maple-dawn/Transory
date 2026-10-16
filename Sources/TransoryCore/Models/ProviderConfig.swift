import Foundation

/// 服务商使用的接口协议。大多数服务商都兼容 OpenAI 的 Chat Completions。
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAICompatible
    case anthropic
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        }
    }
}

/// 一个已配置的模型服务。API Key 不在这里，单独存放在钥匙串（见 `KeychainStore`）。
public struct ProviderConfig: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var baseURL: URL
    public var model: String
    /// 采样温度；为 nil 时不发送，由服务端用默认值。Anthropic 当前模型不接受该参数，适配器会忽略它。
    public var temperature: Double?
    public var isEnabled: Bool
    /// 是否在「其他模型」里参与多模型对比。
    public var includeInComparison: Bool
    /// 自定义提示词模板；为 nil 时用 `PromptBuilder.defaultTemplate`。
    public var promptTemplate: String?
    /// 是否需要 API Key（本地 Ollama 不需要）。
    public var requiresAPIKey: Bool
    /// 可选的模型名，来自「从服务商获取」或手动添加；`model` 是其中正在使用的一个。
    public var models: [String]
    /// 去掉译文里的 `<think>…</think>` 思考过程（部分推理模型会输出）。
    public var hidesThinking: Bool

    public init(
        id: String,
        name: String,
        kind: ProviderKind,
        baseURL: URL,
        model: String,
        temperature: Double? = 0.3,
        isEnabled: Bool = true,
        includeInComparison: Bool = false,
        promptTemplate: String? = nil,
        requiresAPIKey: Bool = true,
        models: [String] = [],
        hidesThinking: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.isEnabled = isEnabled
        self.includeInComparison = includeInComparison
        self.promptTemplate = promptTemplate
        self.requiresAPIKey = requiresAPIKey
        self.models = models
        self.hidesThinking = hidesThinking
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, temperature, isEnabled, includeInComparison
        case promptTemplate, requiresAPIKey, models, hidesThinking
    }

    /// 兼容旧版本保存的配置：新加的字段缺失时用默认值。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        includeInComparison = try c.decodeIfPresent(Bool.self, forKey: .includeInComparison) ?? false
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate)
        requiresAPIKey = try c.decodeIfPresent(Bool.self, forKey: .requiresAPIKey) ?? true
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        hidesThinking = try c.decodeIfPresent(Bool.self, forKey: .hidesThinking) ?? true
    }

    /// 可选模型列表，确保包含当前使用的模型。
    public var modelChoices: [String] {
        model.isEmpty || models.contains(model) ? models : [model] + models
    }
}

public extension ProviderConfig {
    static let anthropic = ProviderConfig(
        id: "anthropic", name: "Anthropic", kind: .anthropic,
        baseURL: URL(string: "https://api.anthropic.com")!,
        model: "claude-opus-5-5", temperature: nil,
        models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    )
    static let openAI = ProviderConfig(
        id: "openai", name: "OpenAI", kind: .openAICompatible,
        baseURL: URL(string: "https://api.openai.com/v1")!,
        model: "", temperature: nil, includeInComparison: true
    )
    static let gemini = ProviderConfig(
        id: "gemini", name: "Google Gemini", kind: .gemini,
        baseURL: URL(string: "https://generativelanguage.googleapis.com")!,
        model: "", includeInComparison: true
    )
    static let deepSeek = ProviderConfig(
        id: "deepseek", name: "DeepSeek", kind: .openAICompatible,
        baseURL: URL(string: "https://api.deepseek.com")!,
        model: "deepseek-chat", includeInComparison: true,
        models: ["deepseek-chat", "deepseek-reasoner"]
    )
    static let ollama = ProviderConfig(
        id: "ollama", name: "Ollama", kind: .openAICompatible,
        baseURL: URL(string: "http://localhost:11434/v1")!,
        model: "", isEnabled: false, requiresAPIKey: false
    )

    /// 首次启动时的默认服务列表。OpenAI、Gemini、Ollama 的模型名留空，让用户在设置里填。
    static let presets: [ProviderConfig] = [.anthropic, .openAI, .gemini, .deepSeek, .ollama]

}
