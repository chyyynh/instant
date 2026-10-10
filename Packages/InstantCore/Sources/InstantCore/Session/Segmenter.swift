import Foundation

/// A recognized character (or short run) and where it sits in the audio.
public struct Token: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(_ text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    var duration: TimeInterval { end - start }
}

/// Splits recognized speech into readable segments.
///
/// Apple's recognizer often omits punctuation in fast conversation, so punctuation alone yields
/// paragraph-long lines. Its token time ranges are contiguous — silence is absorbed into the
/// duration of the token that follows it — so a pause shows up as one unusually long token.
/// Measured on a podcast clip: median token 0.12s, p95 0.36s; pauses run 0.5–1s.
public struct Segmenter: Sendable, Equatable {
    /// A token lasting longer than this starts a new segment (the speaker paused before it).
    public var pauseThreshold: TimeInterval = 0.45
    /// Segments longer than this are split again at their longest internal pause.
    public var maxLength = 40
    /// Never split this close to either end of a long segment, to avoid one- or two-character scraps.
    public var minPieceLength = 6

    static let terminators: Set<String> = ["。", "！", "？", "!", "?", "．"]

    public init() {}

    /// Returns complete segments and the trailing in-progress text.
    /// - Parameter isFinal: When true, the trailing text is complete too and is returned as a segment.
    public func split(_ tokens: [Token], isFinal: Bool) -> (segments: [String], tail: String) {
        var groups: [[Token]] = []
        var current: [Token] = []
        for token in Self.characters(tokens) {
            if token.duration > pauseThreshold, !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(token)
            if Self.terminators.contains(token.text) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        var pieces = groups.flatMap(splitLong)
        // The last piece is still being spoken unless the recognizer finalized it or it ended a sentence.
        var tail: [Token] = []
        if !isFinal, let last = pieces.last, !Self.terminators.contains(last.last?.text ?? "") {
            tail = pieces.removeLast()
        }
        return (pieces.map(Self.text).filter { !$0.isEmpty }, Self.text(tail))
    }

    /// Cuts left to right, choosing each cut only from the first `maxLength` characters, so a cut
    /// never moves as more speech is appended — otherwise every growth would re-split (and
    /// re-translate) the earlier pieces.
    private func splitLong(_ group: [Token]) -> [[Token]] {
        guard group.count > maxLength else { return [group] }
        let window = minPieceLength...min(maxLength, group.count - minPieceLength)
        guard !window.isEmpty else { return [group] }
        // Best cut: the longest pause, nudged toward commas and casual sentence-final particles;
        // ties (e.g. untimed volatile text) go to the latest position, keeping pieces long.
        let cut = window.max { a, b in
            let (scoreA, scoreB) = (cutScore(group, before: a), cutScore(group, before: b))
            return scoreA != scoreB ? scoreA < scoreB : a < b
        }!
        return [Array(group[..<cut])] + splitLong(Array(group[cut...]))
    }

    static let clauseEndings = ["けど", "ので", "から", "さ", "ね", "よ", "、"]

    private func cutScore(_ group: [Token], before index: Int) -> Double {
        let preceding = group[max(0, index - 2)..<index].map(\.text).joined()
        let next = group[index].text
        let endsClause = Self.clauseEndings.contains { preceding.hasSuffix($0) }
            && !["ん", "い", "う", "っ"].contains(next) // さん, ない, よう, よっ… are inside words
        return group[index].duration + (endsClause ? 0.25 : 0)
    }

    /// One token per character. Multi-character runs (volatile results carry a single time range
    /// for the whole text) are spread evenly, which carries no pause information but keeps
    /// punctuation and length handling working.
    static func characters(_ tokens: [Token]) -> [Token] {
        tokens.flatMap { token -> [Token] in
            let characters = Array(token.text)
            guard characters.count > 1 else { return [token] }
            let step = token.duration / Double(characters.count)
            return characters.enumerated().map { offset, character in
                let start = token.start + step * Double(offset)
                return Token(String(character), start: start, end: start + step)
            }
        }
    }

    static func text(_ tokens: [Token]) -> String {
        let joined = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop segments that are nothing but punctuation.
        return joined.allSatisfy { terminators.contains(String($0)) } ? "" : joined
    }
}
