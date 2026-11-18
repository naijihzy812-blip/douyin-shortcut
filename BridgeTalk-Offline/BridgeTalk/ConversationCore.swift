import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese, english, japanese, korean, french, german, spanish, italian, portuguese, russian
    var id: String { rawValue }
    var name: String {
        switch self {
        case .chinese: return "中文（普通话）"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        case .italian: return "意大利语"
        case .portuguese: return "葡萄牙语（巴西）"
        case .russian: return "俄语"
        }
    }
    var speechLocale: String {
        switch self {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        }
    }
    var translationCode: String { self == .chinese ? "zh-Hans" : String(speechLocale.prefix(2)) }
}

enum Direction: String, CaseIterable, Identifiable {
    case automatic, first, second
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "两种语言自动判断（试验）"
        case .first: return "语言 A → 语言 B"
        case .second: return "语言 B → 语言 A"
        }
    }
}

struct SpeechCandidate: Identifiable {
    var id: String { locale }
    let text: String
    let locale: String
    let confidence: Float
    var languageName: String { AppLanguage.allCases.first { $0.speechLocale == locale }?.name ?? locale }
}

// Reject ambiguous results instead of silently choosing the wrong direction.
enum CandidateRouter {
    static func pick(_ candidates: [SpeechCandidate]) -> SpeechCandidate? {
        let usable = candidates.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard usable.count == 2 else { return nil }
        let ranked = usable.sorted { score($0) > score($1) }
        guard let first = ranked.first, score(first) >= 0.55,
              score(first) - score(ranked[1]) >= 0.22 else { return nil }
        return first
    }

    static func score(_ item: SpeechCandidate) -> Float {
        let letters = item.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let matchingCount = letters.filter { scalar in
            let v = scalar.value
            switch item.locale.prefix(2) {
            case "zh": return (0x3400...0x9FFF).contains(v)
            case "ja": return (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v)
            case "ko": return (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)
            case "ru": return (0x0400...0x052F).contains(v)
            default: return (65...90).contains(v) || (97...122).contains(v) || (0x00C0...0x024F).contains(v)
            }
        }.count
        let matching = Float(matchingCount) / Float(letters.count)
        return max(0, min(1, item.confidence)) * 0.8 + matching * 0.2
    }
}

struct SilenceGate {
    enum Decision: Equatable { case keepRecording, submit, discard }
    let threshold: Float
    var firstVoice: TimeInterval?
    var lastVoice: TimeInterval?
    var voicedSamples = 0

    mutating func update(elapsed: TimeInterval, power: Float) -> Decision {
        if power > threshold {
            firstVoice = firstVoice ?? elapsed
            lastVoice = elapsed
            voicedSamples += 1
        }
        if let lastVoice, elapsed - lastVoice >= 1.0 { return voicedSamples >= 3 ? .submit : .discard }
        if let firstVoice {
            if elapsed - firstVoice >= 18 { return voicedSamples >= 3 ? .submit : .discard }
        } else if elapsed >= 18 { return .discard }
        return .keepRecording
    }
}
