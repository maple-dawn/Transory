import Foundation

/// OpenAI Chat Completions 协议。OpenAI、DeepSeek、Ollama、OpenRouter 等都走这个适配器。
public struct OpenAICompatibleProvider: StreamingProvider {
    public let config: ProviderConfig
    let apiKey: String
    let transport: any HTTPTransport

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

    struct Body: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let stream: Bool
    }

    func makeURLRequest(for request: TranslateRequest) throws -> URLRequest {
        try checkCredentials(apiKey: apiKey)
        let body = Body(
            model: config.model,
            messages: [
                Message(role: "system", content: PromptBuilder.systemPrompt(for: request, template: config.promptTemplate)),
                Message(role: "user", content: request.text),
            ],
            temperature: config.temperature,
            stream: true
        )
        var urlRequest = try jsonRequest(url: config.baseURL.appending(path: "chat/completions"), body: body)
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        return urlRequest
    }

    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        struct APIError: Decodable { let message: String? }
        let choices: [Choice]?
        let error: APIError?
    }

    func parse(_ payload: String) throws -> StreamEvent {
        if payload == "[DONE]" { return .done }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
        if let error = chunk.error {
            throw ProviderError.api(message: error.message ?? payload)
        }
        guard let text = chunk.choices?.first?.delta?.content, !text.isEmpty else { return .ignore }
        return .delta(text)
    }
}
