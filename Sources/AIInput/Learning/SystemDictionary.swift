import AVFoundation
import CoreServices
import Foundation

/// 系统自带词典（通常是牛津美式词典）的离线释义，卡片生成前就能先显示。
enum SystemDictionary {
    static func definition(for word: String) -> String? {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (term as NSString).length)
        guard let text = DCSCopyTextDefinition(nil, term as CFString, range)?.takeRetainedValue() else {
            return nil
        }
        let value = (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.count > 900 ? String(value.prefix(900)) + "…" : value
    }
}

/// 用系统语音朗读英文（离线、免费）。
@MainActor
final class Speaker {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = trimmed.split(separator: " ").count > 1 ? 0.46 : 0.4
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
