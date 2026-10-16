import Foundation
import NaturalLanguage

public enum LanguageDetector {
    /// 识别文本的主要语言，返回 `Language.targets` 里对应的一项；识别不出时返回 nil。
    public static func detect(_ text: String) -> Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        switch code {
        case "zh-Hans": return .simplifiedChinese
        case "zh-Hant": return .traditionalChinese
        default: return Language.targets.first { $0.code == code }
        }
    }

    /// 源语言为「自动」时，如果原文已经是目标语言，就改为译成 `fallback`（默认英语）。
    /// 简体与繁体视为同一种语言。
    public static func resolveTarget(
        for text: String,
        source: Language,
        target: Language,
        fallback: Language = .english
    ) -> Language {
        guard source == .auto, let detected = detect(text) else { return target }
        let isChinese: (Language) -> Bool = { $0.code.hasPrefix("zh") }
        let same = detected == target || (isChinese(detected) && isChinese(target))
        if same {
            return target == fallback ? .simplifiedChinese : fallback
        }
        return target
    }
}
