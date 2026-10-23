import Foundation

/// 与本机 Codex CLI 交互：查找可执行文件、登录状态、浏览器登录、模型列表。
/// ChatGPT 账户的登录和凭证都由 Codex 自己管理，Transory 只调用命令。
public enum CodexCLI {
    /// 常见安装位置。从 Finder 启动的 App 拿不到终端里的 PATH，所以逐个查找。
    static let candidatePaths = [
        "~/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.npm-global/bin/codex",
        "~/.bun/bin/codex",
        "~/.volta/bin/codex",
    ]

    public static let installCommand = "npm install -g @openai/codex"

    /// 找到 Codex CLI；都找不到时用登录 shell 的 `command -v` 再试一次。
    public static func locate() async -> URL? {
        let fileManager = FileManager.default
        for path in candidatePaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        guard let output = try? await run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v codex"]),
              output.status == 0
        else { return nil }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    public static func isInstalled(at executable: URL) -> Bool {
        executable.isFileURL && FileManager.default.isExecutableFile(atPath: executable.path)
    }

    // MARK: - 登录状态

    public enum AuthStatus: Equatable, Sendable {
        /// 已用 ChatGPT 账户登录。
        case chatGPT
        /// Codex 用的是 API Key 登录，不是 ChatGPT 账户。
        case apiKey
        case signedOut
        case notInstalled
        case failed(String)
    }

    public static func status(executable: URL) async -> AuthStatus {
        guard isInstalled(at: executable) else { return .notInstalled }
        do {
            let output = try await run(executable, ["login", "status"])
            return parseStatus(output.stdout + output.stderr, exitCode: output.status)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parseStatus(_ output: String, exitCode: Int32) -> AuthStatus {
        let text = output.lowercased()
        if text.contains("not logged in") { return .signedOut }
        if text.contains("logged in") {
            if text.contains("chatgpt") { return .chatGPT }
            if text.contains("api key") { return .apiKey }
        }
        return exitCode == 0 ? .signedOut : .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func logout(executable: URL) async throws {
        let output = try await run(executable, ["logout"])
        if output.status != 0 {
            throw ProviderError.api(message: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
    }

    // MARK: - 模型列表

    public static func models(executable: URL) async throws -> [String] {
        let output = try await run(executable, ["debug", "models"])
        guard output.status == 0 else {
            throw ProviderError.api(message: output.stderr.isEmpty ? "无法读取 Codex 模型列表" : output.stderr)
        }
        return try parseModels(Data(output.stdout.utf8))
    }

    /// 只保留会在模型选择器里显示的模型（visibility 为 list）。
    static func parseModels(_ data: Data) throws -> [String] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                let slug: String
                let visibility: String?
            }
            let models: [Model]
        }
        return try JSONDecoder().decode(Catalog.self, from: data).models
            .filter { ($0.visibility ?? "list") == "list" }
            .map(\.slug)
    }

    // MARK: - 浏览器登录

    #if os(macOS)
    /// 一次 `codex login`：它会打开浏览器走 OAuth，并在本机等待回调，授权完成后退出。
    public final class LoginSession: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var output = ""
        private var urlHandler: (@Sendable (URL) -> Void)?

        /// 登录页地址（从 Codex 的输出里取），用于「复制登录链接」「重新打开浏览器」。
        public private(set) var loginURL: URL?

        public init(executable: URL) {
            process.executableURL = executable
            process.arguments = ["login"]
            process.standardInput = FileHandle.nullDevice
        }

        /// 开始登录，等它结束；返回是否成功。`onURL` 在拿到登录页地址时回调。
        public func run(onURL: @escaping @Sendable (URL) -> Void) async -> Bool {
            urlHandler = onURL
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.consume(String(decoding: data, as: UTF8.self))
            }
            return await withCheckedContinuation { continuation in
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: process.terminationStatus == 0)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: false)
                }
            }
        }

        public func cancel() {
            if process.isRunning { process.terminate() }
        }

        private func consume(_ text: String) {
            lock.lock()
            output += text
            let found = loginURL == nil ? CodexCLI.firstURL(in: output) : nil
            if let found { loginURL = found }
            let handler = urlHandler
            lock.unlock()
            if let found { handler?(found) }
        }
    }
    #endif

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "https" }
    }

    // MARK: - 运行命令

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// 运行一条命令并收集输出。
    static func run(_ executable: URL, _ arguments: [String], stdin: Data? = nil) async throws -> Output {
        try await run(executable, arguments, stdin: stdin, box: ProcessBox())
    }

    /// 运行 Codex 的空目录：翻译不需要读写任何文件。
    static var workingDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "transory-codex", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
