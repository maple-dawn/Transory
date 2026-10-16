import AppKit
import Foundation
import Testing
@testable import TransoryCore

@Suite struct LanguageDetectorTests {
    @Test func detectsCommonLanguages() {
        #expect(LanguageDetector.detect("The quick brown fox jumps over the lazy dog.") == .english)
        #expect(LanguageDetector.detect("最好的工具会融入工作流之中，无需切换标签页。") == .simplifiedChinese)
    }

    @Test func switchesTargetWhenSourceAlreadyMatches() {
        let chinese = "最好的工具会融入工作流之中，无需切换标签页。"
        #expect(LanguageDetector.resolveTarget(for: chinese, source: .auto, target: .simplifiedChinese) == .english)
        #expect(LanguageDetector.resolveTarget(for: chinese, source: .auto, target: .traditionalChinese) == .english)
        #expect(LanguageDetector.resolveTarget(for: "Hello there, how are you today?", source: .auto, target: .english) == .simplifiedChinese)
    }

    @Test func keepsTargetOtherwise() {
        #expect(LanguageDetector.resolveTarget(for: "Hello there, how are you today?", source: .auto, target: .simplifiedChinese) == .simplifiedChinese)
        // 用户手动指定源语言时不做调整。
        #expect(LanguageDetector.resolveTarget(for: "最好的工具", source: .simplifiedChinese, target: .simplifiedChinese) == .simplifiedChinese)
    }
}

@Suite struct LineMapperTests {
    let lines = [
        RecognizedLine(id: 0, text: "Q3 Release Notes", boundingBox: .zero),
        RecognizedLine(id: 1, text: "Offline mode", boundingBox: .zero),
    ]

    @Test func joinsWithNewlines() {
        #expect(LineMapper.join(lines) == "Q3 Release Notes\nOffline mode")
    }

    @Test func splitsWhenLineCountsMatch() {
        #expect(LineMapper.split("第三季度发布说明\n\n 离线模式 \n", matching: lines) == ["第三季度发布说明", "离线模式"])
    }

    @Test func refusesWhenLineCountsDiffer() {
        #expect(LineMapper.split("第三季度发布说明，离线模式", matching: lines) == nil)
    }
}

@Suite struct TextRecognizerTests {
    @Test func recognizesRenderedText() async throws {
        let image = try #require(Self.render(["Hello Transory", "Offline translation"]))
        let lines = try await TextRecognizer.recognize(image)
        #expect(lines.count == 2)
        #expect(lines.first?.text.contains("Hello") == true)
        #expect(lines.last?.text.contains("Offline") == true)
        // 坐标为左上角原点：第一行在上方。
        if lines.count == 2 {
            #expect(lines[0].boundingBox.minY < lines[1].boundingBox.minY)
        }
    }

    static func render(_ lines: [String]) -> CGImage? {
        let image = NSImage(size: NSSize(width: 600, height: 240), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black]
            for (index, line) in lines.enumerated() {
                line.draw(at: NSPoint(x: 30, y: 40 + index * 90), withAttributes: attributes)
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

@Suite struct TranslationSessionTests {
    @MainActor
    @Test func collectsResultsAndReportsFinish() async throws {
        let transport = MockTransport([#"data: {"choices":[{"delta":{"content":"你好"}}]}"#, "data: [DONE]"])
        let provider = OpenAICompatibleProvider(config: .deepSeek, apiKey: "k", transport: transport)
        let session = TranslationSession()

        var finished: [String] = []
        session.onFinish = { id, _, _ in finished.append(id) }
        session.run(sampleRequest, providers: [provider])
        #expect(session.isTranslating)

        for _ in 0..<50 where session.isTranslating {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isTranslating)
        #expect(session.results["deepseek"]?.text == "你好")
        #expect(session.results["deepseek"]?.phase.isFinished == true)
        #expect(finished == ["deepseek"])
        #expect(session.lastRequest == sampleRequest)
    }

    @MainActor
    @Test func presentShowsStoredResultWithoutRequest() {
        let session = TranslationSession()
        session.present(ModelResult(text: "旧译文", phase: .finished(duration: .zero)), providerID: "anthropic", request: sampleRequest)
        #expect(session.results["anthropic"]?.text == "旧译文")
        #expect(!session.isTranslating)
    }
}
