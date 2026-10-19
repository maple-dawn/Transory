import CryptoKit
import Foundation

/// 内置的 ChatGPT 账户登录（OAuth 2.0 授权码 + PKCE），流程与 Codex CLI 相同：
/// 浏览器打开 auth.openai.com 授权，回调到本机 127.0.0.1:1455，用授权码换取令牌。
public enum ChatGPTAuth {
    static let issuer = URL(string: "https://auth.openai.com")!
    /// Codex 的公开 OAuth 客户端 ID。
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    static let originator = "codex_cli_rs"
    static let callbackPath = "/auth/callback"
    static let ports: [UInt16] = [1455, 1457]

    static var tokenEndpoint: URL { issuer.appending(path: "oauth/token") }

    struct PKCE {
        let verifier: String
        let challenge: String

        static func generate() -> PKCE {
            from(verifier: randomBase64URL(byteCount: 64))
        }

        static func from(verifier: String) -> PKCE {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return PKCE(verifier: verifier, challenge: base64URL(Data(digest)))
        }
    }

    static func authorizeURL(redirectURI: String, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: issuer.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator),
        ]
        return components.url!
    }

    static func formRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents 不会转义 "+"，表单里要手动处理。
        let body = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        request.httpBody = Data(body.utf8)
        return request
    }

    static func codeExchangeRequest(code: String, redirectURI: String, verifier: String) -> URLRequest {
        formRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
        ])
    }

    struct TokenResponse: Decodable {
        let id_token: String?
        let access_token: String
        let refresh_token: String?
    }

    static func requestTokens(_ request: URLRequest, session: URLSession = .shared) async throws -> TokenResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: oauthErrorMessage(data))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// OAuth 错误体形如 {"error": "...", "error_description": "..."}，也可能是 {"error": {"message": "..."}}。
    static func oauthErrorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = object["error_description"] as? String { return description }
            if let error = object["error"] as? String { return error }
        }
        return ProviderError.message(from: data)
    }

    // MARK: - 工具

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 读取 JWT 的载荷（不校验签名，只用来显示账户信息和判断过期）。
    static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// 登录后得到的令牌和从中读出的账户信息。保存在钥匙串里。
public struct ChatGPTTokens: Codable, Equatable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String?
    public var email: String?
    public var plan: String?
    public var expiresAt: Date?

    init(idToken: String, accessToken: String, refreshToken: String) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        let idClaims = ChatGPTAuth.jwtClaims(idToken)
        let auth = idClaims["https://api.openai.com/auth"] as? [String: Any]
        accountID = auth?["chatgpt_account_id"] as? String
        plan = auth?["chatgpt_plan_type"] as? String
        email = idClaims["email"] as? String
        if let exp = ChatGPTAuth.jwtClaims(accessToken)["exp"] as? Double {
            expiresAt = Date(timeIntervalSince1970: exp)
        }
    }

    /// 刷新返回的字段可能不全，缺的沿用旧值。
    init(response: ChatGPTAuth.TokenResponse, previous: ChatGPTTokens?) throws {
        guard let idToken = response.id_token ?? previous?.idToken,
              let refreshToken = response.refresh_token ?? previous?.refreshToken
        else { throw ProviderError.api(message: "登录服务没有返回完整的令牌") }
        self.init(idToken: idToken, accessToken: response.access_token, refreshToken: refreshToken)
    }

    /// 还剩不到一分钟就算过期，提前刷新。
    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

/// 令牌的存放位置：正式使用钥匙串，测试和快照用内存。
public protocol ChatGPTCredentialStore: Sendable {
    func load(_ providerID: String) -> ChatGPTTokens?
    func save(_ tokens: ChatGPTTokens?, for providerID: String)
}

public struct KeychainCredentialStore: ChatGPTCredentialStore {
    private let keychain = KeychainStore(service: "app.transory.chatgpt-oauth")

    public init() {}

    public func load(_ providerID: String) -> ChatGPTTokens? {
        let text = keychain.apiKey(for: providerID)
        guard !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(ChatGPTTokens.self, from: Data(text.utf8))
    }

    public func save(_ tokens: ChatGPTTokens?, for providerID: String) {
        let text = tokens.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        keychain.setAPIKey(text, for: providerID)
    }
}

public final class InMemoryCredentialStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ChatGPTTokens] = [:]

    public init() {}

    public func load(_ providerID: String) -> ChatGPTTokens? {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID]
    }

    public func save(_ tokens: ChatGPTTokens?, for providerID: String) {
        lock.lock()
        storage[providerID] = tokens
        lock.unlock()
    }
}

/// 一个 ChatGPT 账户服务的登录状态：读取、刷新、保存令牌。并发刷新会合并成一次。
public actor ChatGPTSession {
    public let providerID: String
    private let store: any ChatGPTCredentialStore
    private let urlSession: URLSession
    private var cached: ChatGPTTokens?
    private var loaded = false
    private var refreshTask: Task<ChatGPTTokens, Error>?

    public init(providerID: String, store: any ChatGPTCredentialStore, urlSession: URLSession = .shared) {
        self.providerID = providerID
        self.store = store
        self.urlSession = urlSession
    }

    // MARK: 共享实例

    private static let registry = SessionRegistry()

    /// 每个服务一个共享会话，避免多个窗口同时刷新令牌。
    public static func shared(for providerID: String) -> ChatGPTSession {
        registry.session(for: providerID)
    }

    /// 快照、测试时改用内存存储，不访问钥匙串。
    public static func useInMemoryStore() {
        registry.useInMemory()
    }

    // MARK: 令牌

    public func tokens() -> ChatGPTTokens? {
        if !loaded {
            cached = store.load(providerID)
            loaded = true
        }
        return cached
    }

    /// 可用的令牌：快过期时先刷新。未登录时抛错。
    public func validTokens() async throws -> ChatGPTTokens {
        guard let current = tokens() else {
            throw ProviderError.api(message: "尚未登录 ChatGPT 账户，请在设置中登录")
        }
        guard current.needsRefresh else { return current }
        return try await refresh()
    }

    public func refresh() async throws -> ChatGPTTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens() else {
            throw ProviderError.api(message: "尚未登录 ChatGPT 账户，请在设置中登录")
        }
        let urlSession = urlSession
        let task = Task {
            let response = try await ChatGPTAuth.requestTokens(ChatGPTAuth.refreshRequest(refreshToken: current.refreshToken), session: urlSession)
            return try ChatGPTTokens(response: response, previous: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            save(renewed)
            return renewed
        } catch let ProviderError.http(status, message) where status == 400 || status == 401 {
            // 刷新令牌失效，只能重新登录。
            save(nil)
            throw ProviderError.api(message: "ChatGPT 登录已失效，请重新登录（\(message)）")
        }
    }

    public func save(_ tokens: ChatGPTTokens?) {
        cached = tokens
        loaded = true
        store.save(tokens, for: providerID)
    }

    public func signOut() {
        save(nil)
    }
}

final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: ChatGPTSession] = [:]
    private var store: any ChatGPTCredentialStore = KeychainCredentialStore()

    func session(for providerID: String) -> ChatGPTSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[providerID] { return session }
        let session = ChatGPTSession(providerID: providerID, store: store)
        sessions[providerID] = session
        return session
    }

    func useInMemory() {
        lock.lock()
        store = InMemoryCredentialStore()
        sessions = [:]
        lock.unlock()
    }
}

/// 一次浏览器登录：启动本地回调服务 → 生成授权地址 → 等回调 → 换取令牌并保存。
public final class ChatGPTLoginFlow: @unchecked Sendable {
    private let session: ChatGPTSession
    private let urlSession: URLSession
    private var server: LocalCallbackServer?

    public init(session: ChatGPTSession, urlSession: URLSession = .shared) {
        self.session = session
        self.urlSession = urlSession
    }

    static let successPage = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>Transory</title>
    <body style="font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
    <div style="text-align:center"><h2>登录成功</h2><p>可以关闭此页面，回到 Transory。</p></div></body></html>
    """

    /// 启动回调服务并返回授权页地址，调用方负责在浏览器中打开。
    public func start() async throws -> (url: URL, wait: () async throws -> ChatGPTTokens) {
        let server = try await LocalCallbackServer.start(
            ports: ChatGPTAuth.ports,
            callbackPath: ChatGPTAuth.callbackPath,
            successPage: Self.successPage
        )
        self.server = server
        let pkce = ChatGPTAuth.PKCE.generate()
        let state = ChatGPTAuth.randomBase64URL(byteCount: 32)
        let redirectURI = "http://127.0.0.1:\(server.port)\(ChatGPTAuth.callbackPath)"
        let url = ChatGPTAuth.authorizeURL(redirectURI: redirectURI, pkce: pkce, state: state)
        let session = session
        let urlSession = urlSession
        return (url, {
            defer { server.stop() }
            let query = try await server.waitForCallback()
            guard query["state"] == state else { throw ProviderError.api(message: "登录回调校验失败，请重试") }
            if let error = query["error"] {
                throw ProviderError.api(message: query["error_description"] ?? error)
            }
            guard let code = query["code"], !code.isEmpty else { throw ProviderError.api(message: "登录回调缺少授权码") }
            let response = try await ChatGPTAuth.requestTokens(
                ChatGPTAuth.codeExchangeRequest(code: code, redirectURI: redirectURI, verifier: pkce.verifier),
                session: urlSession
            )
            let tokens = try ChatGPTTokens(response: response, previous: nil)
            await session.save(tokens)
            return tokens
        })
    }

    public func cancel() {
        server?.stop()
    }
}
