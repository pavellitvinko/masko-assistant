import Foundation

enum SpeechTier: String, Codable {
    case emote, mutter, comment
}

struct SpeechEvent: Codable {
    let text: String
    let tier: SpeechTier
    let emotion: String?
}
