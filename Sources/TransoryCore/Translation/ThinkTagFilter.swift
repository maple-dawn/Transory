import Foundation

/// 流式去掉 `<think>…</think>` 思考内容。标签可能被拆在两个片段之间，所以要暂存可能是半个标签的结尾。
public struct ThinkTagFilter: Sendable {
    private static let open = "<think>"
    private static let close = "</think>"

    private var inside = false
    private var pending = ""
    /// 思考块之后的换行一般是格式噪音，去掉正文开头的空白。
    private var emittedAny = false

    public init() {}

    public mutating func feed(_ chunk: String) -> String {
        var text = pending + chunk
        pending = ""
        var output = ""
        while !text.isEmpty {
            let tag = inside ? Self.close : Self.open
            if let range = text.range(of: tag) {
                if !inside { output += text[..<range.lowerBound] }
                inside.toggle()
                text = String(text[range.upperBound...])
            } else {
                let keep = Self.partialSuffixLength(of: text, matching: tag)
                let split = text.index(text.endIndex, offsetBy: -keep)
                if !inside { output += text[..<split] }
                pending = String(text[split...])
                text = ""
            }
        }
        return trimLeading(output)
    }

    /// 流结束时调用，返回暂存的、最终不是标签的文字。
    public mutating func finish() -> String {
        defer { pending = "" }
        return inside ? "" : trimLeading(pending)
    }

    private mutating func trimLeading(_ text: String) -> String {
        guard !emittedAny else { return text }
        let trimmed = String(text.drop(while: \.isWhitespace))
        if !trimmed.isEmpty { emittedAny = true }
        return trimmed
    }

    /// `text` 结尾与 `tag` 开头重合的最长长度（不含整个标签）。
    private static func partialSuffixLength(of text: String, matching tag: String) -> Int {
        for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1)
        where text.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }
}
