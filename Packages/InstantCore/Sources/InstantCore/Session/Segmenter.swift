import Foundation

/// A recognized character (or short run) and where it sits in the audio.
public struct Token: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// False when the time range was spread evenly over a multi-character run, which says
    /// nothing about pauses between its characters.
    public let isTimed: Bool

    public init(_ text: String, start: TimeInterval, end: TimeInterval, isTimed: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.isTimed = isTimed
    }

    var duration: TimeInterval { end - start }
    /// Duration usable as pause evidence: zero for untimed tokens.
    var pauseEvidence: TimeInterval { isTimed ? duration : 0 }
}

/// A piece of recognized speech and where it sits in the audio (seconds since the session began).
public struct Segment: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
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
    public func split(_ tokens: [Token], isFinal: Bool) -> (segments: [Segment], tail: Segment?) {
        var groups: [[Token]] = []
        var current: [Token] = []
        for token in Self.characters(tokens) {
            if token.pauseEvidence > pauseThreshold, !current.isEmpty {
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
        return (pieces.compactMap(Self.segment), Self.segment(tail))
    }

    static func segment(_ tokens: [Token]) -> Segment? {
        let text = text(tokens)
        guard !text.isEmpty, let first = tokens.first, let last = tokens.last else { return nil }
        return Segment(text: text, start: first.start, end: last.end)
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
        // Never inside a katakana or kanji word (アメ|リカ, 唐|辛子).
        let insideWord = Self.wordScript(group[index - 1].text) != nil
            && Self.wordScript(group[index - 1].text) == Self.wordScript(next)
        return group[index].pauseEvidence + (endsClause ? 0.25 : 0) - (insideWord ? 1 : 0)
    }

    private enum Script { case katakana, kanji }

    private static func wordScript(_ text: String) -> Script? {
        guard let scalar = text.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x30A0...0x30FF, 0x31F0...0x31FF: return .katakana // includes ー
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .kanji
        default: return nil
        }
    }

    /// One token per character. Multi-character runs (volatile results carry a single time range
    /// for the whole text) are spread evenly, which carries no pause information but keeps
    /// punctuation and length handling working.
    static func characters(_ tokens: [Token]) -> [Token] {
        tokens.flatMap { token -> [Token] in
            let characters = Array(token.text)
            guard characters.count > 1 else { return [token] }
            // Volatile results come as one run spanning everything since the last final (seen:
            // 13 characters over 34s); spreading that would make every character look like a pause.
            let step = token.duration / Double(characters.count)
            return characters.enumerated().map { offset, character in
                let start = token.start + step * Double(offset)
                return Token(String(character), start: start, end: start + step, isTimed: false)
            }
        }
    }

    static func text(_ tokens: [Token]) -> String {
        let joined = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop segments that are nothing but punctuation.
        return joined.allSatisfy { terminators.contains(String($0)) } ? "" : joined
    }
}
