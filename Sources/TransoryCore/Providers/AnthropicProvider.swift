import Foundation

/// Anthropic Messages API（原生协议，流式）。
///
/// 当前 Claude 模型不接受自定义 `temperature`，所以这里不发送；
/// 改用 `output_config.effort = "low"` 换取更低的翻译延迟。
public struct AnthropicProvider: StreamingProvider {
    public let config: ProviderConfig
    let apiKey: String
    let transport: any HTTPTransport

    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// 支持 `output_config.effort` 的模型系列。
    static let effortModelPrefixes = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5"]
    /// 可能因安全分类器拒绝、需要服务端自动降级重试的模型。
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public init(config: ProviderConfig, apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
    }

    public func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
        streamTranslation(request)
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct OutputConfig: Encodable {
        let effort: String
    }

    struct Body: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let stream: Bool
        let output_config: OutputConfig?
        let fallbacks: String?
    }

    var supportsEffort: Bool {
        Self.effortModelPrefixes.contains { config.model.hasPrefix($0) }
    }

    /// 服务端降级（`fallbacks: "default"`）只在 Anthropic 官方接口上可用。
    var usesServerFallback: Bool {
        config.baseURL.host() == "api.anthropic.com" && Self.fallbackModels.contains(config.model)
    }

    func makeURLRequest(for request: TranslateRequest) throws -> URLRequest {
        try checkCredentials(apiKey: apiKey)
        let body = Body(
            model: config.model,
            max_tokens: 32_000,
            system: PromptBuilder.systemPrompt(for: request, template: config.promptTemplate),
            messages: [Message(role: "user", content: request.text)],
            stream: true,
            output_config: supportsEffort ? OutputConfig(effort: "low") : nil,
            fallbacks: usesServerFallback ? "default" : nil
        )
        var urlRequest = try jsonRequest(url: config.baseURL.appending(path: "v1/messages"), body: body)
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if usesServerFallback {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        return urlRequest
    }

    struct Event: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stop_reason: String?
        }
        struct APIError: Decodable { let message: String? }
        let type: String
        let delta: Delta?
        let error: APIError?
    }

    func parse(_ payload: String) throws -> StreamEvent {
        let event = try JSONDecoder().decode(Event.self, from: Data(payload.utf8))
        switch event.type {
        case "content_block_delta":
            // 思考过程（thinking_delta 等）不展示，只取正文。
            guard event.delta?.type == "text_delta", let text = event.delta?.text else { return .ignore }
            return .delta(text)
        case "message_delta":
            if event.delta?.stop_reason == "refusal" { throw ProviderError.refused }
            return .ignore
        case "message_stop":
            return .done
        case "error":
            throw ProviderError.api(message: event.error?.message ?? payload)
        default:
            return .ignore
        }
    }
}
