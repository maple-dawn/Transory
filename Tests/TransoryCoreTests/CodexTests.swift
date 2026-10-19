import Foundation
import Testing
@testable import TransoryCore

@Suite struct CodexTests {
    /// 写一个假的 codex 可执行脚本，返回它的位置。
    static func fakeCodex(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "codex")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func config(executable: URL, model: String = "", effort: String? = nil) -> ProviderConfig {
        ProviderConfig(id: "chatgpt", name: "ChatGPT 账户", kind: .codex, baseURL: executable, model: model,
                       temperature: nil, requiresAPIKey: false, reasoningEffort: effort)
    }

    @Test func parsesExecEvents() {
        #expect(CodexProvider.parse(#"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"你好"}}"#) == .text("你好"))
        // 配置警告之类的 error 条目不算失败。
        #expect(CodexProvider.parse(#"{"type":"item.completed","item":{"id":"i","type":"error","message":"ignored setting"}}"#) == .ignore)
        #expect(CodexProvider.parse(#"{"type":"turn.failed","error":{"message":"boom"}}"#) == .failed("boom"))
        #expect(CodexProvider.parse("not json") == .ignore)
    }

    @Test func buildsArguments() {
        let config = Self.config(executable: URL(fileURLWithPath: "/tmp/codex"), model: "m1", effort: "low")
        let args = CodexProvider(config: config).arguments
        #expect(args.starts(with: ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only"]))
        #expect(args.contains("--json"))
        #expect(args.contains("model_reasoning_effort=\"low\""))
        #expect(args.suffix(3) == ["-m", "m1", "-"])
    }

    @Test func parsesLoginStatus() {
        #expect(CodexCLI.parseStatus("Logged in using ChatGPT\n", exitCode: 0) == .chatGPT)
        #expect(CodexCLI.parseStatus("Logged in using an API key - sk-***\n", exitCode: 0) == .apiKey)
        #expect(CodexCLI.parseStatus("Not logged in\n", exitCode: 1) == .signedOut)
    }

    @Test func parsesModelCatalog() throws {
        let json = #"{"models":[{"slug":"a","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"b"}]}"#
        #expect(try CodexCLI.parseModels(Data(json.utf8)) == ["a", "b"])
    }

    @Test func extractsLoginURL() {
        let output = "Starting local login server on http://localhost:1455.\nIf your browser did not open, navigate to this URL to authenticate:\n\nhttps://auth.example.com/oauth/authorize?client=x&state=y\n"
        #expect(CodexCLI.firstURL(in: output)?.host() == "auth.example.com")
    }

    @Test func translatesThroughTheCLI() async throws {
        // 假的 codex：读掉 stdin，输出一条配置警告和一条回复。
        let codex = try Self.fakeCodex("""
        cat > /dev/null
        echo '{"type":"thread.started","thread_id":"t"}'
        echo '{"type":"item.completed","item":{"id":"0","type":"error","message":"ignored"}}'
        echo '{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"好的工具不碍事。"}}'
        echo '{"type":"turn.completed"}'
        """)
        let provider = CodexProvider(config: Self.config(executable: codex))
        #expect(try await provider.translateAll(sampleRequest) == "好的工具不碍事。")
    }

    @Test func reportsFailures() async throws {
        let codex = try Self.fakeCodex("""
        cat > /dev/null
        echo '{"type":"turn.failed","error":{"message":"You have hit your usage limit."}}'
        exit 1
        """)
        let provider = CodexProvider(config: Self.config(executable: codex))
        await #expect(throws: ProviderError.api(message: "ChatGPT 账户的用量已达上限，请稍后再试")) {
            try await provider.translateAll(sampleRequest)
        }
    }

    @Test func reportsMissingExecutable() async {
        let provider = CodexProvider(config: Self.config(executable: URL(fileURLWithPath: "/nonexistent/codex")))
        await #expect(throws: ProviderError.self) { try await provider.translateAll(sampleRequest) }
    }

    @Test func readsStatusFromTheCLI() async throws {
        let codex = try Self.fakeCodex("""
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then echo "Logged in using ChatGPT"; exit 0; fi
        exit 2
        """)
        #expect(await CodexCLI.status(executable: codex) == .chatGPT)
        #expect(await CodexCLI.status(executable: URL(fileURLWithPath: "/nonexistent/codex")) == .notInstalled)
    }
}
