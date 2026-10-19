import Foundation

/// 「添加模型服务」里可选的服务模板：选中后生成一份 `ProviderConfig`。
public struct ProviderTemplate: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case account, apiKey, local, custom

        public var title: String {
            switch self {
            case .account: "账户登录（在浏览器中授权，无需 API Key）"
            case .apiKey: "需要 API Key"
            case .local: "本地模型（无需 Key，离线可用）"
            case .custom: "自定义"
            }
        }
    }

    public let id: String
    public let name: String
    public let note: String
    public let group: Group
    public let kind: ProviderKind
    public let baseURL: URL
    public let models: [String]
    /// 自定义模板可以重复添加；其他模板每种只添加一次。
    public var isRepeatable: Bool { group == .custom }

    public init(id: String, name: String, note: String, group: Group, kind: ProviderKind, baseURL: String, models: [String] = []) {
        self.id = id
        self.name = name
        self.note = note
        self.group = group
        self.kind = kind
        self.baseURL = URL(string: baseURL)!
        self.models = models
    }

    /// 生成配置。`id` 由调用方决定（重复添加的自定义服务需要不同 id）。
    public func makeConfig(id: String) -> ProviderConfig {
        ProviderConfig(
            id: id,
            name: name,
            kind: kind,
            baseURL: baseURL,
            model: models.first ?? "",
            temperature: kind == .anthropic ? nil : 0.3,
            requiresAPIKey: group == .apiKey || group == .custom,
            models: models
        )
    }

    /// Codex CLI 的默认位置；添加服务时会再自动查找一次。
    public static let defaultCodexPath = ("~/.local/bin/codex" as NSString).expandingTildeInPath

    public static let all: [ProviderTemplate] = [
        ProviderTemplate(id: "chatgpt", name: "ChatGPT 账户", note: "使用 ChatGPT 订阅额度", group: .account, kind: .codex,
                         baseURL: URL(fileURLWithPath: defaultCodexPath).absoluteString),
        ProviderTemplate(id: "anthropic", name: "Anthropic", note: "Claude 系列", group: .apiKey, kind: .anthropic,
                         baseURL: "https://api.anthropic.com", models: ProviderConfig.anthropic.models),
        ProviderTemplate(id: "openai", name: "OpenAI", note: "GPT 系列", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://api.openai.com/v1"),
        ProviderTemplate(id: "gemini", name: "Google Gemini", note: "Gemini 系列", group: .apiKey, kind: .gemini,
                         baseURL: "https://generativelanguage.googleapis.com"),
        ProviderTemplate(id: "deepseek", name: "DeepSeek", note: "OpenAI 兼容", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://api.deepseek.com", models: ProviderConfig.deepSeek.models),
        ProviderTemplate(id: "openrouter", name: "OpenRouter", note: "一个 Key 用多家模型", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://openrouter.ai/api/v1"),
        ProviderTemplate(id: "siliconflow", name: "硅基流动", note: "OpenAI 兼容", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://api.siliconflow.cn/v1"),
        ProviderTemplate(id: "moonshot", name: "Kimi", note: "OpenAI 兼容", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://api.moonshot.cn/v1"),
        ProviderTemplate(id: "zhipu", name: "智谱 GLM", note: "OpenAI 兼容", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://open.bigmodel.cn/api/paas/v4"),
        ProviderTemplate(id: "qwen", name: "通义千问", note: "OpenAI 兼容", group: .apiKey, kind: .openAICompatible,
                         baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        ProviderTemplate(id: "ollama", name: "Ollama", note: "localhost:11434", group: .local, kind: .openAICompatible,
                         baseURL: "http://localhost:11434/v1"),
        ProviderTemplate(id: "lmstudio", name: "LM Studio", note: "localhost:1234", group: .local, kind: .openAICompatible,
                         baseURL: "http://localhost:1234/v1"),
        ProviderTemplate(id: "custom-openai", name: "自定义 OpenAI 兼容", note: "填写任意接口地址", group: .custom, kind: .openAICompatible,
                         baseURL: "https://example.com/v1"),
        ProviderTemplate(id: "custom-anthropic", name: "自定义 Anthropic 兼容", note: "代理或私有部署", group: .custom, kind: .anthropic,
                         baseURL: "https://example.com"),
    ]
}
