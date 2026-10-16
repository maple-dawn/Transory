import Foundation

/// OCR 的多行文字一次请求翻译：按行拼接，结果再按行拆回去，以便覆盖到原图对应位置。
public enum LineMapper {
    public static func join(_ lines: [RecognizedLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// 译文按行拆分（忽略空行）。行数与原文一致时返回逐行对应的译文，否则返回 nil，
    /// 调用方此时只能并排显示，不能覆盖原图。
    public static func split(_ translation: String, matching lines: [RecognizedLine]) -> [String]? {
        let parts = translation
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.count == lines.count ? parts : nil
    }
}
