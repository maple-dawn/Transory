import Foundation

/// 术语表中的一条：原文术语 → 固定译法。
public struct GlossaryEntry: Hashable, Codable, Sendable {
    public var term: String
    public var translation: String

    public init(term: String, translation: String) {
        self.term = term
        self.translation = translation
    }
}

/// 一次翻译请求，与具体模型无关。
public struct TranslateRequest: Sendable, Equatable {
    public var text: String
    public var source: Language
    public var target: Language
    public var style: TranslationStyle
    public var glossary: [GlossaryEntry]

    public init(
        text: String,
        source: Language = .auto,
        target: Language = .simplifiedChinese,
        style: TranslationStyle = .natural,
        glossary: [GlossaryEntry] = []
    ) {
        self.text = text
        self.source = source
        self.target = target
        self.style = style
        self.glossary = glossary
    }
}
