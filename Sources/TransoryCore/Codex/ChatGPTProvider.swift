import Foundation

/// 内置登录方式：用 ChatGPT 账户的令牌直接调用 Codex 后端（Responses API 格式，流式）。
public struct ChatGPTProvider: TranslationProvider {
    public let config: ProviderConfig
    let session: ChatGPTSession
    let transport: any HTTPTransport

    static let baseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
    /// 模型列表接口要求带客户端版本号。
    static let clientVersion = "0.162.0"

    public init(config: ProviderConfig, session: ChatGPTSession, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.session = session
        self.transport = transport
    }

    struct Content: Encodable {
        let type = "input_text"
        let text: String
    }

    struct Message: Encodable {
        let type = "message"
        let role: String
        let content: [Content]
    }

    struct Reasoning: Encodable {
        let effort: String
    }

    struct Body: Encodable {
        let model: String
        let stream = true
        let input: [Message]
        let tool_choice = "auto"
        let parallel_tool_calls = false
        let reasoning: Reasoning?
        let store = false
        let include: [String] = []
    }

    static func headers(_ tokens: ChatGPTTokens, into request: inout URLRequest) {
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "authorization")
        if let accountID = tokens.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue(ChatGPTAuth.originator, forHTTPHeaderField: "originator")
    }

    func makeURLRequest(for request: TranslateRequest, tokens: ChatGPTTokens) throws -> URLRequest {
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty { throw ProviderError.missingModel }
        let body = Body(
            model: config.model,
            input: [
                Message(role: "developer", content: [Content(text: PromptBuilder.systemPrompt(for: request, template: config.promptTemplate))]),
                Message(role: "user", content: [Content(text: request.text)]),
            ],
            reasoning: config.reasoningEffort.map(Reasoning.init(effort:))
        )
        var urlRequest = URLRequest(url: Self.baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "session_id")
        Self.headers(tokens, into: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    struct Event: Decodable {
        struct Failure: Decodable { let message: String? }
        struct Response: Decodable { let error: Failure? }
        let type: String
        let delta: String?
        let response: Response?
        let error: Failure?
        let message: String?
    }

    static func parse(_ payload: String) throws -> StreamEvent {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else { return .ignore }
        switch event.type {
        case "response.output_text.delta":
            return event.delta.map { $0.isEmpty ? .ignore : .delta($0) } ?? .ignore
        case "response.completed", "response.done":
            return .done
        case "response.failed", "response.incomplete":
            throw ProviderError.api(message: CodexProvider.friendly(event.response?.error?.message ?? "ChatGPT 返回了错误"))
        case "error":
            throw ProviderError.api(message: CodexProvider.friendly(event.error?.message ?? event.message ?? payload))
        default:
            return .ignore
        }
    }

    public func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tokens = try await session.validTokens()
                    let urlRequest = try makeURLRequest(for: request, tokens: tokens)
                    lines: for try await line in try await transport.lines(for: urlRequest) {
                        guard let payload = SSE.payload(from: line) else { continue }
                        switch try Self.parse(payload) {
                        case .delta(let text): continuation.yield(text)
                        case .ignore: continue
                        case .done: break lines
                        }
                    }
                    continuation.finish()
                } catch let ProviderError.http(status, _) where status == 401 {
                    continuation.finish(throwing: ProviderError.api(message: "ChatGPT 登录已失效，请在设置中重新登录"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 读取账户可用的模型（与 `codex debug models` 的格式相同）。
    public static func models(session: ChatGPTSession, urlSession: URLSession = .shared) async throws -> [String] {
        let tokens = try await session.validTokens()
        var request = URLRequest(url: baseURL.appending(path: "models").appending(queryItems: [
            URLQueryItem(name: "client_version", value: clientVersion),
        ]))
        request.timeoutInterval = 30
        headers(tokens, into: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: ProviderError.message(from: data))
        }
        return try CodexCLI.parseModels(data)
    }
}
