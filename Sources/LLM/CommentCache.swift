import Foundation

class CommentCache {
    private var lastComments: [String] = []
    private let limit = 20
    
    func isOriginal(_ text: String) -> Bool {
        !lastComments.contains(normalize(text))
    }
    
    func add(_ text: String) {
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { return }
        lastComments.append(cleaned)
        if lastComments.count > limit {
            lastComments.removeFirst()
        }
    }
    
    func clear() {
        lastComments.removeAll()
    }

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character.isWhitespace {
                return character
            }
            return " "
        }
        return String(filtered).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
