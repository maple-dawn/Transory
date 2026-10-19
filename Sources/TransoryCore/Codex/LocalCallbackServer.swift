import Foundation
import Network

/// OAuth 回调用的临时本地 HTTP 服务，只监听 127.0.0.1。
/// 浏览器授权完成后会跳转到 `http://127.0.0.1:<port>/auth/callback?code=…&state=…`。
final class LocalCallbackServer: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "transory.oauth-callback")
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var received: Result<[String: String], Error>?
    private let callbackPath: String
    private let successPage: String

    private init(listener: NWListener, port: UInt16, callbackPath: String, successPage: String) {
        self.listener = listener
        self.port = port
        self.callbackPath = callbackPath
        self.successPage = successPage
    }

    /// 依次尝试这些端口，返回第一个能监听的。端口 0 表示由系统分配（测试用）。
    static func start(ports: [UInt16], callbackPath: String, successPage: String) async throws -> LocalCallbackServer {
        var lastError: Error = ProviderError.api(message: "无法启动本地登录回调服务")
        for port in ports {
            do {
                return try await start(port: port, callbackPath: callbackPath, successPage: successPage)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func start(port: UInt16, callbackPath: String, successPage: String) async throws -> LocalCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "transory.oauth-callback.start")
        let actualPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? port) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                    listener.cancel()
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        let server = LocalCallbackServer(listener: listener, port: actualPort, callbackPath: callbackPath, successPage: successPage)
        listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }
        listener.stateUpdateHandler = nil
        return server
    }

    /// 等待回调，返回查询参数。
    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let received {
                lock.unlock()
                continuation.resume(with: received)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func stop() {
        finish(.failure(CancellationError()))
        listener.cancel()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard received == nil else {
            lock.unlock()
            return
        }
        received = result
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // 第一行形如 "GET /auth/callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            if components?.path == self.callbackPath {
                var query: [String: String] = [:]
                for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
                self.respond(connection, status: "200 OK", body: self.successPage)
                self.finish(.success(query))
            } else {
                self.respond(connection, status: "404 Not Found", body: "")
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// 保证 continuation 只被 resume 一次。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
