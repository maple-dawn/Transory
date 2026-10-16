import Foundation

/// 多模型对比中某个模型的最新状态。
public struct ComparisonUpdate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case streaming
        case finished(duration: Duration)
        case failed(String)
    }

    public let providerID: String
    /// 到目前为止累积的完整译文。
    public let text: String
    public let phase: Phase
}

/// 并发请求多个模型，谁先返回就先推送谁的进度。
public enum ComparisonRunner {
    public static func run(
        _ request: TranslateRequest,
        providers: [any TranslationProvider]
    ) -> AsyncStream<ComparisonUpdate> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for provider in providers {
                        group.addTask {
                            await stream(provider, request: request, into: continuation)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func stream(
        _ provider: any TranslationProvider,
        request: TranslateRequest,
        into continuation: AsyncStream<ComparisonUpdate>.Continuation
    ) async {
        let id = provider.config.id
        let clock = ContinuousClock()
        let start = clock.now
        var text = ""
        do {
            for try await chunk in provider.translate(request) {
                text += chunk
                continuation.yield(ComparisonUpdate(providerID: id, text: text, phase: .streaming))
            }
            continuation.yield(ComparisonUpdate(
                providerID: id,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                phase: .finished(duration: clock.now - start)
            ))
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(ComparisonUpdate(providerID: id, text: text, phase: .failed(error.localizedDescription)))
        }
    }
}
