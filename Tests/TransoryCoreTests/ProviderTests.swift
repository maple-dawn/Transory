import Foundation
import Testing
@testable import TransoryCore

/// 返回预设 SSE 行、并记下发出的请求的假传输层。
final class MockTransport: HTTPTransport, @unchecked Sendable {
    let lines: [String]
    private(set) var lastRequest: URLRequest?

    init(_ lines: [String]) {
        self.lines = lines
    }

    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        let lines = lines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

let sampleRequest = TranslateRequest(text: "Hello", source: .english, target: .simplifiedChinese)

@Suite struct OpenAICompatibleProviderTests {
    @Test func streamsDeltasAndBuildsRequest() async throws {
        let transport = MockTransport([
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"好"}}]}"#,
            "data: [DONE]",
        ])
        let config = ProviderConfig.deepSeek
        let provider = OpenAICompatibleProvider(config: config, apiKey: "sk-test", transport: transport)

        #expect(try await provider.translateAll(sampleRequest) == "你好")

        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        let body = try jsonBody(request)
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["content"] == "Hello")
        #expect(messages.first?["content"]?.contains("Simplified Chinese") == true)
    }

    @Test func omitsAuthorizationForLocalModels() throws {
        var config = ProviderConfig.ollama
        config.model = "qwen3"
        let provider = OpenAICompatibleProvider(config: config, apiKey: "", transport: MockTransport([]))
        let request = try provider.makeURLRequest(for: sampleRequest)
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func requiresKeyAndModel() {
        let noKey = OpenAICompatibleProvider(config: .deepSeek, apiKey: "", transport: MockTransport([]))
        #expect(throws: ProviderError.missingAPIKey) { try noKey.makeURLRequest(for: sampleRequest) }

        let noModel = OpenAICompatibleProvider(config: .openAI, apiKey: "sk", transport: MockTransport([]))
        #expect(throws: ProviderError.missingModel) { try noModel.makeURLRequest(for: sampleRequest) }
    }

    @Test func surfacesStreamErrors() async {
        let transport = MockTransport([#"data: {"error":{"message":"quota exceeded"}}"#])
        let provider = OpenAICompatibleProvider(config: .deepSeek, apiKey: "sk", transport: transport)
        await #expect(throws: ProviderError.api(message: "quota exceeded")) {
            try await provider.translateAll(sampleRequest)
        }
    }
}

@Suite struct AnthropicProviderTests {
    @Test func streamsTextAndSkipsThinking() async throws {
        let transport = MockTransport([
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"你"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"好"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        let provider = AnthropicProvider(config: .anthropic, apiKey: "sk-ant", transport: transport)

        #expect(try await provider.translateAll(sampleRequest) == "你好")

        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let body = try jsonBody(request)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["temperature"] == nil)
        #expect(body["fallbacks"] as? String == "default")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect((body["system"] as? String)?.contains("Simplified Chinese") == true)
    }

    @Test func noFallbackOnProxies() throws {
        var config = ProviderConfig.anthropic
        config.baseURL = URL(string: "https://proxy.example.com")!
        let request = try AnthropicProvider(config: config, apiKey: "k", transport: MockTransport([]))
            .makeURLRequest(for: sampleRequest)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try jsonBody(request)["fallbacks"] == nil)
    }

    @Test func throwsOnRefusal() async {
        let transport = MockTransport([
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
        ])
        let provider = AnthropicProvider(config: .anthropic, apiKey: "k", transport: transport)
        await #expect(throws: ProviderError.refused) { try await provider.translateAll(sampleRequest) }
    }

    @Test func throwsOnErrorEvent() async {
        let transport = MockTransport([
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ])
        let provider = AnthropicProvider(config: .anthropic, apiKey: "k", transport: transport)
        await #expect(throws: ProviderError.api(message: "Overloaded")) { try await provider.translateAll(sampleRequest) }
    }
}

@Suite struct GeminiProviderTests {
    @Test func streamsPartsAndBuildsRequest() async throws {
        let transport = MockTransport([
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"你"}]}}]}"#,
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"好"}]},"finishReason":"STOP"}]}"#,
        ])
        var config = ProviderConfig.gemini
        config.model = "gemini-test"
        let provider = GeminiProvider(config: config, apiKey: "g-key", transport: transport)

        #expect(try await provider.translateAll(sampleRequest) == "你好")

        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent?alt=sse")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        let body = try jsonBody(request)
        #expect(body["systemInstruction"] != nil)
        #expect(body["contents"] != nil)
    }
}

@Suite struct PromptAndComparisonTests {
    @Test func fillsTemplateVariables() {
        let request = TranslateRequest(
            text: "x", source: .japanese, target: .english, style: .formal,
            glossary: [GlossaryEntry(term: "翻訳", translation: "translation")]
        )
        let prompt = PromptBuilder.systemPrompt(for: request, template: "{source_lang}|{target_lang}|{style}|{glossary}")
        #expect(prompt == "Japanese|English|formal and professional|翻訳 → translation")
    }

    @Test func emptyTemplateFallsBackToDefault() {
        let prompt = PromptBuilder.systemPrompt(for: sampleRequest, template: "")
        #expect(prompt.contains("professional translator"))
        #expect(prompt.contains("Glossary (always use these translations): none"))
    }

    @Test func comparisonReportsEachProvider() async {
        let ok = OpenAICompatibleProvider(
            config: .deepSeek, apiKey: "k",
            transport: MockTransport([#"data: {"choices":[{"delta":{"content":"好"}}]}"#, "data: [DONE]"])
        )
        let failing = OpenAICompatibleProvider(config: .openAI, apiKey: "k", transport: MockTransport([]))

        var final: [String: ComparisonUpdate] = [:]
        for await update in ComparisonRunner.run(sampleRequest, providers: [ok, failing]) {
            final[update.providerID] = update
        }

        #expect(final["deepseek"]?.text == "好")
        if case .finished = final["deepseek"]?.phase {} else { Issue.record("deepseek should finish") }
        #expect(final["openai"]?.phase == .failed(ProviderError.missingModel.localizedDescription))
    }
}
