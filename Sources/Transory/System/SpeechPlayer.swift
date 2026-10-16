import AVFoundation
import TransoryCore

/// 朗读文本。再次调用会打断上一段。
@MainActor
final class SpeechPlayer {
    static let shared = SpeechPlayer()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: Language?) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let language, language != .auto {
            utterance.voice = AVSpeechSynthesisVoice(language: language.code)
        }
        synthesizer.speak(utterance)
    }
}
