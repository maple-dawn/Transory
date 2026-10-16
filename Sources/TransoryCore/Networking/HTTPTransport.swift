import Foundation

/// 发出请求并按行返回流式响应体。抽成协议是为了在测试里替换成假数据。
public protocol HTTPTransport: Sendable {
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error>
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64 * 1024 { break }
            }
            throw ProviderError.http(status: http.statusCode, message: ProviderError.message(from: body))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Server-Sent Events 的最小解析：只取 `data:` 行。
/// 三家服务商的每个事件都只有一行 data，所以逐行处理即可（`AsyncBytes.lines` 会丢掉空行）。
enum SSE {
    static func payload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var rest = line.dropFirst(5)
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }
}
