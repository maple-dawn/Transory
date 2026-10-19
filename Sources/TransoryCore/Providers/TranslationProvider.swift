import Foundation

/// 所有模型服务的统一接口：输入一次翻译请求，流式返回译文片段。
public protocol TranslationProvider: Sendable {
    var config: ProviderConfig { get }
    func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error>
}

public extension TranslationProvider {
    /// 等待流结束，返回完整译文。
    func translateAll(_ request: TranslateRequest) async throws -> String {
        var result = ""
        for try await chunk in translate(request) {
            result += chunk
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ProviderError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case missingModel
    case invalidResponse
    case http(status: Int, message: String)
    case api(message: String)
    case refused

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未填写 API Key"
        case .missingModel: "尚未选择模型"
        case .invalidResponse: "服务返回了无法识别的响应"
        case .http(let status, let message): "请求失败（HTTP \(status)）：\(message)"
        case .api(let message): "服务返回错误：\(message)"
        case .refused: "模型拒绝了这次请求"
        }
    }

    /// 三家服务商的错误体都形如 `{"error": {"message": "..."}}`，取不到时退回原文。
    static func message(from body: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message {
            return message
        }
        return String(decoding: body.prefix(500), as: UTF8.self)
    }
}

/// 一行 SSE 数据解析后的结果。
enum StreamEvent: Equatable {
    case delta(String)
    case ignore
    case done
}

/// 基于 HTTP + SSE 的服务商共用的流程：构造请求 → 逐行解析 → 产出译文片段。
protocol StreamingProvider: TranslationProvider {
    var transport: any HTTPTransport { get }
    func makeURLRequest(for request: TranslateRequest) throws -> URLRequest
    func parse(_ payload: String) throws -> StreamEvent
}

extension StreamingProvider {
    func streamTranslation(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(for: request)
                    var filter = config.hidesThinking ? ThinkTagFilter() : nil
                    func emit(_ text: String) {
                        let visible = filter?.feed(text) ?? text
                        if !visible.isEmpty { continuation.yield(visible) }
                    }
                    func flush() {
                        if let rest = filter?.finish(), !rest.isEmpty { continuation.yield(rest) }
                    }
                    lines: for try await line in try await transport.lines(for: urlRequest) {
                        guard let payload = SSE.payload(from: line) else { continue }
                        switch try parse(payload) {
                        case .delta(let text): emit(text)
                        case .ignore: continue
                        case .done: break lines
                        }
                    }
                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func checkCredentials(apiKey: String) throws {
        if config.requiresAPIKey && apiKey.isEmpty { throw ProviderError.missingAPIKey }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty { throw ProviderError.missingModel }
    }

    func jsonRequest(url: URL, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

/// 根据配置创建对应的适配器。
public enum ProviderFactory {
    public static func make(
        _ config: ProviderConfig,
        apiKey: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> any TranslationProvider {
        switch config.kind {
        case .openAICompatible: OpenAICompatibleProvider(config: config, apiKey: apiKey, transport: transport)
        case .anthropic: AnthropicProvider(config: config, apiKey: apiKey, transport: transport)
        case .gemini: GeminiProvider(config: config, apiKey: apiKey, transport: transport)
        case .codex:
            switch config.codexAccess {
            case .builtIn: ChatGPTProvider(config: config, session: .shared(for: config.id), transport: transport)
            case .cli: CodexProvider(config: config)
            }
        }
    }
}
