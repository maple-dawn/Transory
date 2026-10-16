import Foundation

/// 翻译语言。`code` 使用 BCP 47 标签，`auto` 表示自动检测。
public struct Language: Hashable, Codable, Sendable, Identifiable {
    public let code: String
    public let name: String
    /// 写进提示词里的英文名，模型对英文语言名理解最稳定。
    public let promptName: String

    public var id: String { code }

    public init(code: String, name: String, promptName: String) {
        self.code = code
        self.name = name
        self.promptName = promptName
    }

    public static let auto = Language(code: "auto", name: "自动检测", promptName: "the detected source language")
    public static let simplifiedChinese = Language(code: "zh-Hans", name: "简体中文", promptName: "Simplified Chinese")
    public static let traditionalChinese = Language(code: "zh-Hant", name: "繁体中文", promptName: "Traditional Chinese")
    public static let english = Language(code: "en", name: "英语", promptName: "English")
    public static let japanese = Language(code: "ja", name: "日语", promptName: "Japanese")
    public static let korean = Language(code: "ko", name: "韩语", promptName: "Korean")
    public static let french = Language(code: "fr", name: "法语", promptName: "French")
    public static let german = Language(code: "de", name: "德语", promptName: "German")
    public static let spanish = Language(code: "es", name: "西班牙语", promptName: "Spanish")
    public static let russian = Language(code: "ru", name: "俄语", promptName: "Russian")

    /// 可作为目标语言的列表（不含自动检测）。
    public static let targets: [Language] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
        .french, .german, .spanish, .russian,
    ]

    /// 可作为源语言的列表。
    public static let sources: [Language] = [.auto] + targets

    /// 按代码查找；找不到时返回 nil。
    public static func from(code: String) -> Language? {
        sources.first { $0.code == code }
    }
}

/// 译文风格。
public enum TranslationStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case natural, formal, casual, literal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .natural: "自然"
        case .formal: "正式"
        case .casual: "口语"
        case .literal: "直译"
        }
    }

    var promptDescription: String {
        switch self {
        case .natural: "natural and fluent, as a native speaker would write it"
        case .formal: "formal and professional"
        case .casual: "casual and conversational"
        case .literal: "close to the original wording and structure"
        }
    }
}
