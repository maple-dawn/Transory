import Foundation
import Testing
@testable import TransoryCore

@Suite struct ThinkTagFilterTests {
    func run(_ chunks: [String]) -> String {
        var filter = ThinkTagFilter()
        return chunks.map { filter.feed($0) }.joined() + filter.finish()
    }

    @Test func removesThinkBlock() {
        #expect(run(["<think>先想一想</think>\n\n你好"]) == "你好")
    }

    @Test func handlesTagsSplitAcrossChunks() {
        #expect(run(["<thi", "nk>推理", "过程</th", "ink>", "\n译文", "结束"]) == "译文结束")
    }

    @Test func keepsTextWithoutTags() {
        #expect(run(["a < b", " 并且 <", "tag>"]) == "a < b 并且 <tag>")
    }

    @Test func dropsUnclosedThinking() {
        #expect(run(["正文", "<think>没写完"]) == "正文")
    }
}

@Suite struct ModelListerTests {
    @Test func parsesOpenAIAndAnthropicLists() throws {
        let json = #"{"data":[{"id":"b-model"},{"id":"a-model"},{"id":"b-model"}]}"#
        #expect(try ModelLister.parse(Data(json.utf8), kind: .openAICompatible) == ["a-model", "b-model"])
        #expect(try ModelLister.parse(Data(json.utf8), kind: .anthropic) == ["a-model", "b-model"])
    }

    @Test func parsesGeminiAndKeepsGenerativeModels() throws {
        let json = #"""
        {"models":[
          {"name":"models/gemini-x","supportedGenerationMethods":["generateContent"]},
          {"name":"models/embedding-x","supportedGenerationMethods":["embedContent"]}
        ]}
        """#
        #expect(try ModelLister.parse(Data(json.utf8), kind: .gemini) == ["gemini-x"])
    }

    @Test func buildsRequestsPerKind() {
        let openAI = ModelLister.makeRequest(.deepSeek, apiKey: "k")
        #expect(openAI.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(openAI.value(forHTTPHeaderField: "authorization") == "Bearer k")

        let anthropic = ModelLister.makeRequest(.anthropic, apiKey: "k")
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }
}

@Suite struct ProviderConfigTests {
    @Test func decodesConfigsSavedByOlderVersions() throws {
        let legacy = #"""
        [{"id":"deepseek","name":"DeepSeek","kind":"openAICompatible","baseURL":"https://api.deepseek.com",
          "model":"deepseek-chat","temperature":0.3,"isEnabled":true,"includeInComparison":true,"requiresAPIKey":true}]
        """#
        let configs = try JSONDecoder().decode([ProviderConfig].self, from: Data(legacy.utf8))
        #expect(configs.first?.models == [])
        #expect(configs.first?.hidesThinking == true)
        #expect(configs.first?.modelChoices == ["deepseek-chat"])
    }

    @Test func templatesProduceUsableConfigs() throws {
        let ollama = try #require(ProviderTemplate.all.first { $0.id == "ollama" })
        let config = ollama.makeConfig(id: "ollama")
        #expect(config.requiresAPIKey == false)
        #expect(config.baseURL.absoluteString == "http://localhost:11434/v1")

        let anthropic = try #require(ProviderTemplate.all.first { $0.id == "anthropic" })
        #expect(anthropic.makeConfig(id: "anthropic").temperature == nil)
        #expect(Set(ProviderTemplate.all.map(\.id)).count == ProviderTemplate.all.count)
    }

    @Test func hidesThinkingWhileStreaming() async throws {
        let transport = MockTransport([
            #"data: {"choices":[{"delta":{"content":"<think>推理"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"</think>\n你好"}}]}"#,
            "data: [DONE]",
        ])
        let provider = OpenAICompatibleProvider(config: .deepSeek, apiKey: "k", transport: transport)
        #expect(try await provider.translateAll(sampleRequest) == "你好")
    }
}
