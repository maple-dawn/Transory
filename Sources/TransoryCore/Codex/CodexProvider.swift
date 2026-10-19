import Foundation

/// 通过 Codex CLI 翻译，使用用户 ChatGPT 账户的额度。
///
/// 运行 `codex exec --json`，只读沙盒、临时会话、在空目录里执行；
/// Codex 一次性返回整段回复，所以译文不是逐字出现的。
public struct CodexProvider: TranslationProvider {
    public let config: ProviderConfig

    /// Codex 可执行文件的位置，存在配置的 `baseURL` 里（file URL）。
    var executable: URL { config.baseURL }

    public init(config: ProviderConfig) {
        self.config = config
    }

    var arguments: [String] {
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--ignore-user-config", "--json"]
        if let effort = config.reasoningEffort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        if !config.model.isEmpty {
            args += ["-m", config.model]
        }
        args.append("-")
        return args
    }

    func prompt(for request: TranslateRequest) -> String {
        PromptBuilder.systemPrompt(for: request, template: config.promptTemplate)
            + "\n\nDo not run commands or read files. The text to translate is between the markers.\n<<<TEXT\n"
            + request.text
            + "\nTEXT>>>"
    }

    enum Event: Equatable {
        case text(String)
        case failed(String)
        case ignore
    }

    /// 解析 `codex exec --json` 的一行事件。
    static func parse(_ line: String) -> Event {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return .ignore }
        switch type {
        case "item.completed":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message" else { return .ignore }
            return .text(item["text"] as? String ?? "")
        case "turn.failed":
            let error = object["error"] as? [String: Any]
            return .failed(error?["message"] as? String ?? "Codex 执行失败")
        case "error":
            return .failed(object["message"] as? String ?? "Codex 执行失败")
        default:
            return .ignore
        }
    }

    public func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
        let executable = executable
        let arguments = arguments
        let input = Data(prompt(for: request).utf8)
        return AsyncThrowingStream { continuation in
            let box = ProcessBox()
            let task = Task.detached {
                do {
                    guard CodexCLI.isInstalled(at: executable) else {
                        throw ProviderError.api(message: "没有找到 Codex CLI，请先安装：\(CodexCLI.installCommand)")
                    }
                    let output = try await CodexCLI.run(executable, arguments, stdin: input, box: box)
                    var produced = false
                    for line in output.stdout.split(whereSeparator: \.isNewline) {
                        switch Self.parse(String(line)) {
                        case .text(let text) where !text.isEmpty:
                            continuation.yield(produced ? "\n\n" + text : text)
                            produced = true
                        case .failed(let message):
                            throw ProviderError.api(message: Self.friendly(message))
                        default:
                            continue
                        }
                    }
                    if !produced {
                        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ProviderError.api(message: Self.friendly(detail.isEmpty ? "Codex 没有返回译文" : String(detail.suffix(300))))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.terminate()
            }
        }
    }

    /// 常见错误换成能看懂的提示。
    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("not logged in") || lower.contains("login") && lower.contains("required") {
            return "Codex 尚未登录，请在设置中使用 ChatGPT 登录"
        }
        if lower.contains("usage limit") || lower.contains("rate limit") {
            return "ChatGPT 账户的用量已达上限，请稍后再试"
        }
        return message
    }
}

/// 让翻译被取消时能结束正在运行的 Codex 进程。
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = cancelled
        lock.unlock()
        if shouldStop { process.terminate() }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}

extension CodexCLI {
    /// 运行命令并收集输出；stdout 和 stderr 并行读取，避免输出过多时管道写满卡住。
    static func run(_ executable: URL, _ arguments: [String], stdin: Data?, box: ProcessBox) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            let out = Pipe()
            let err = Pipe()
            let input = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input
            try process.run()
            box.attach(process)
            if let stdin { input.fileHandleForWriting.write(stdin) }
            try? input.fileHandleForWriting.close()

            let errorReader = err.fileHandleForReading
            async let errorData = Task.detached { errorReader.readDataToEndOfFile() }.value
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let stderrData = await errorData
            process.waitUntilExit()
            if Task.isCancelled { throw CancellationError() }
            return Output(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }.value
    }
}
