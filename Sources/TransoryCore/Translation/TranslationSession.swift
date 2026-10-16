import Foundation
import Observation

/// 某个模型这一次的翻译结果。
public struct ModelResult: Equatable, Sendable {
    public var text: String
    public var phase: ComparisonUpdate.Phase

    public init(text: String, phase: ComparisonUpdate.Phase) {
        self.text = text
        self.phase = phase
    }
}

/// 一个翻译场景（主窗口、浮窗、OCR）的运行状态：发请求、流式收结果、可取消。
@MainActor
@Observable
public final class TranslationSession {
    /// 本次翻译各模型的结果，按服务商 id 索引。
    public private(set) var results: [String: ModelResult] = [:]
    public private(set) var isTranslating = false
    /// 最近一次请求，用于写历史或重译。
    public private(set) var lastRequest: TranslateRequest?

    /// 每个模型结束（成功或失败）时回调。
    @ObservationIgnored
    public var onFinish: ((_ providerID: String, _ request: TranslateRequest, _ result: ModelResult) -> Void)?

    @ObservationIgnored
    private var task: Task<Void, Never>?

    public init() {}

    public func run(_ request: TranslateRequest, providers: [any TranslationProvider]) {
        task?.cancel()
        lastRequest = request
        results = Dictionary(
            providers.map { ($0.config.id, ModelResult(text: "", phase: .streaming)) },
            uniquingKeysWith: { first, _ in first }
        )
        isTranslating = true
        task = Task { [weak self] in
            for await update in ComparisonRunner.run(request, providers: providers) {
                guard let self else { return }
                let result = ModelResult(text: update.text, phase: update.phase)
                self.results[update.providerID] = result
                if update.phase != .streaming {
                    self.onFinish?(update.providerID, request, result)
                }
            }
            self?.isTranslating = false
        }
    }

    /// 直接展示一个已有结果（例如从历史记录打开），不发请求。
    public func present(_ result: ModelResult, providerID: String, request: TranslateRequest) {
        cancel()
        lastRequest = request
        results = [providerID: result]
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isTranslating = false
    }

    public func reset() {
        cancel()
        results = [:]
        lastRequest = nil
    }
}

public extension ComparisonUpdate.Phase {
    /// 结果底栏的简短状态文字。
    var statusText: String {
        switch self {
        case .streaming: "翻译中…"
        case .finished(let duration):
            duration.formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
        case .failed(let message): message
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
