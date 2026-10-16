import Foundation

/// 「从服务商获取」：查询服务商当前可用的模型名。
public enum ModelLister {
    public static func fetch(_ config: ProviderConfig, apiKey: String, session: URLSession = .shared) async throws -> [String] {
        if config.requiresAPIKey && apiKey.isEmpty { throw ProviderError.missingAPIKey }
        let (data, response) = try await session.data(for: makeRequest(config, apiKey: apiKey))
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: ProviderError.message(from: data))
        }
        return try parse(data, kind: config.kind)
    }

    static func makeRequest(_ config: ProviderConfig, apiKey: String) -> URLRequest {
        var request: URLRequest
        switch config.kind {
        case .openAICompatible:
            request = URLRequest(url: config.baseURL.appending(path: "models"))
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        case .anthropic:
            request = URLRequest(url: config.baseURL.appending(path: "v1/models").appending(queryItems: [URLQueryItem(name: "limit", value: "100")]))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request = URLRequest(url: config.baseURL.appending(path: "v1beta/models").appending(queryItems: [URLQueryItem(name: "pageSize", value: "200")]))
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 30
        return request
    }

    static func parse(_ data: Data, kind: ProviderKind) throws -> [String] {
        let ids: [String]
        switch kind {
        case .openAICompatible, .anthropic:
            // OpenAI 与 Anthropic 都是 {"data": [{"id": "..."}]}
            struct Response: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            ids = try JSONDecoder().decode(Response.self, from: data).data.map(\.id)
        case .gemini:
            struct Response: Decodable {
                struct Model: Decodable {
                    let name: String
                    let supportedGenerationMethods: [String]?
                }
                let models: [Model]
            }
            ids = try JSONDecoder().decode(Response.self, from: data).models
                .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
                .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.sorted()
    }
}
