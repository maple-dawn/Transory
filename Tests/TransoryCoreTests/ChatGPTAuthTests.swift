import Foundation
import Testing
@testable import TransoryCore

/// 生成一个不签名的 JWT（测试只读载荷）。
func fakeJWT(_ claims: [String: Any]) -> String {
    let header = ChatGPTAuth.base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = ChatGPTAuth.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).sig"
}

@Suite struct ChatGPTAuthTests {
    @Test func pkceChallengeIsBase64URLSHA256() {
        // 期望值由 openssl 独立计算：printf … | openssl dgst -sha256 -binary | base64url
        let pkce = ChatGPTAuth.PKCE.from(verifier: "transory-test-verifier")
        #expect(pkce.challenge == "Vz3qJbmUUwy2iltwrx3ZKD55HEnZqJK0eZ9VI0rzjH8")
        #expect(ChatGPTAuth.PKCE.generate().verifier.count > 43)
    }

    @Test func buildsAuthorizeURL() throws {
        let pkce = ChatGPTAuth.PKCE.from(verifier: "v")
        let url = ChatGPTAuth.authorizeURL(redirectURI: "http://127.0.0.1:1455/auth/callback", pkce: pkce, state: "s")
        let items = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "auth.openai.com")
        #expect(url.path() == "/oauth/authorize")
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == ChatGPTAuth.clientID)
        #expect(items["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "s")
        #expect(items["scope"]?.contains("offline_access") == true)
        #expect(items["codex_cli_simplified_flow"] == "true")
    }

    @Test func encodesTokenRequestsAsForms() throws {
        let request = ChatGPTAuth.codeExchangeRequest(code: "a+b c", redirectURI: "http://127.0.0.1:1455/auth/callback", verifier: "v")
        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=a%2Bb%20c"))
        #expect(body.contains("code_verifier=v"))

        let refresh = String(decoding: try #require(ChatGPTAuth.refreshRequest(refreshToken: "r").httpBody), as: UTF8.self)
        #expect(refresh.contains("grant_type=refresh_token"))
        #expect(refresh.contains("refresh_token=r"))
    }

    @Test func readsAccountFromTokens() throws {
        let idToken = fakeJWT([
            "email": "me@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct_1", "chatgpt_plan_type": "plus"],
        ])
        let accessToken = fakeJWT(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970])
        let tokens = ChatGPTTokens(idToken: idToken, accessToken: accessToken, refreshToken: "r")
        #expect(tokens.email == "me@example.com")
        #expect(tokens.accountID == "acct_1")
        #expect(tokens.plan == "plus")
        #expect(tokens.needsRefresh == false)

        let expired = ChatGPTTokens(idToken: idToken, accessToken: fakeJWT(["exp": Date().timeIntervalSince1970 - 10]), refreshToken: "r")
        #expect(expired.needsRefresh)

        // 刷新返回里没有 id_token / refresh_token 时沿用旧值。
        let renewed = try ChatGPTTokens(response: .init(id_token: nil, access_token: accessToken, refresh_token: nil), previous: tokens)
        #expect(renewed.refreshToken == "r")
        #expect(renewed.accountID == "acct_1")
    }

    @Test func callbackServerReceivesCode() async throws {
        let server = try await LocalCallbackServer.start(ports: [0], callbackPath: "/auth/callback", successPage: "ok")
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/auth/callback?code=abc&state=xyz"))
        async let query = server.waitForCallback()
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        let received = try await query
        #expect(received["code"] == "abc")
        #expect(received["state"] == "xyz")
    }

    @Test func oldConfigsDefaultToCLIAccess() throws {
        let json = #"{"id":"chatgpt","name":"ChatGPT 账户","kind":"codex","baseURL":"file:///tmp/codex","model":"","requiresAPIKey":false}"#
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        #expect(config.codexAccess == .cli)
        #expect(ProviderTemplate.all.first { $0.id == "chatgpt" }?.makeConfig(id: "chatgpt").codexAccess == .builtIn)
    }
}

@Suite struct ChatGPTProviderTests {
    func signedInSession() async -> ChatGPTSession {
        let session = ChatGPTSession(providerID: "chatgpt", store: InMemoryCredentialStore())
        let tokens = ChatGPTTokens(
            idToken: fakeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "acct_1"]]),
            accessToken: fakeJWT(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970]),
            refreshToken: "r"
        )
        await session.save(tokens)
        return session
    }

    func config(model: String = "m1", effort: String? = "low") -> ProviderConfig {
        ProviderConfig(id: "chatgpt", name: "ChatGPT 账户", kind: .codex, baseURL: URL(fileURLWithPath: "/tmp/codex"),
                       model: model, temperature: nil, requiresAPIKey: false, reasoningEffort: effort, codexAccess: .builtIn)
    }

    @Test func streamsResponsesEvents() async throws {
        let transport = MockTransport([
            "event: response.created",
            #"data: {"type":"response.created","response":{"id":"r"}}"#,
            #"data: {"type":"response.output_text.delta","delta":"好的"}"#,
            #"data: {"type":"response.output_text.delta","delta":"工具"}"#,
            #"data: {"type":"response.completed","response":{"id":"r"}}"#,
        ])
        let provider = ChatGPTProvider(config: config(), session: await signedInSession(), transport: transport)
        #expect(try await provider.translateAll(sampleRequest) == "好的工具")

        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "acct_1")
        #expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("Bearer ") == true)
        let body = try jsonBody(request)
        #expect(body["model"] as? String == "m1")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "low")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["role"] as? String } == ["developer", "user"])
    }

    @Test func surfacesFailures() async {
        let transport = MockTransport([#"data: {"type":"response.failed","response":{"error":{"message":"You've hit your usage limit"}}}"#])
        let provider = ChatGPTProvider(config: config(), session: await signedInSession(), transport: transport)
        await #expect(throws: ProviderError.api(message: "ChatGPT 账户的用量已达上限，请稍后再试")) {
            try await provider.translateAll(sampleRequest)
        }
    }

    @Test func requiresSignInAndModel() async {
        let signedOut = ChatGPTSession(providerID: "x", store: InMemoryCredentialStore())
        let provider = ChatGPTProvider(config: config(), session: signedOut, transport: MockTransport([]))
        await #expect(throws: ProviderError.self) { try await provider.translateAll(sampleRequest) }

        let noModel = ChatGPTProvider(config: config(model: ""), session: await signedInSession(), transport: MockTransport([]))
        await #expect(throws: ProviderError.missingModel) { try await noModel.translateAll(sampleRequest) }
    }
}
