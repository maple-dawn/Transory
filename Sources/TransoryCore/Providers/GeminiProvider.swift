import Foundation

/// Google Gemini 原生接口（streamGenerateContent + SSE）。
public struct GeminiProvider: StreamingProvider {
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

    struct Part: Codable { let text: String? }
    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }
    struct GenerationConfig: Encodable { let temperature: Double? }
    struct Body: Encodable {
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    func makeURLRequest(for request: TranslateRequest) throws -> URLRequest {
        try checkCredentials(apiKey: apiKey)
        let body = Body(
            systemInstruction: Content(role: nil, parts: [Part(text: PromptBuilder.systemPrompt(for: request, template: config.promptTemplate))]),
            contents: [Content(role: "user", parts: [Part(text: request.text)])],
            generationConfig: GenerationConfig(temperature: config.temperature)
        )
        let url = config.baseURL
            .appending(path: "v1beta/models/\(config.model):streamGenerateContent")
            .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])
        var urlRequest = try jsonRequest(url: url, body: body)
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return urlRequest
    }

    struct Chunk: Decodable {
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }
        struct APIError: Decodable { let message: String? }
        let candidates: [Candidate]?
        let error: APIError?
    }

    func parse(_ payload: String) throws -> StreamEvent {
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
        if let error = chunk.error {
            throw ProviderError.api(message: error.message ?? payload)
        }
        guard let candidate = chunk.candidates?.first else { return .ignore }
        if candidate.finishReason == "SAFETY" { throw ProviderError.refused }
        let text = candidate.content?.parts.compactMap(\.text).joined() ?? ""
        return text.isEmpty ? .ignore : .delta(text)
    }
}
