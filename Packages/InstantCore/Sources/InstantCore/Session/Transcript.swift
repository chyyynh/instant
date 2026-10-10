import Foundation

public struct Line: Identifiable, Sendable, Equatable {
    /// Position in the transcript; stable while a provisional segment keeps its place.
    public let id: Int
    public let source: String
    public var translation: String?
    /// False while the segment is still part of the recognizer's in-progress result and may be revised.
    public var isFinal: Bool
}

/// The running transcript, split into segments.
///
/// Apple's recognizer can go 10+ seconds between final results, so segments that are already
/// complete inside the volatile result (ended by punctuation or a pause, see `Segmenter`) are
/// surfaced as provisional lines right away. Translations are cached by segment text, so a
/// provisional line that survives into the final isn't translated twice.
///
/// Pure state so the event handling can be tested without audio or models.
public struct Transcript: Sendable, Equatable {
    /// Final lines followed by provisional lines.
    public private(set) var lines: [Line] = []
    /// The segment still being spoken.
    public private(set) var volatile = ""
    /// Rough translation of (a recent snapshot of) `volatile`, when drafts are enabled.
    public private(set) var draftTranslation: String?

    public var segmenter = Segmenter()

    private var finalCount = 0
    /// Provisional segments locked in by `settleTail()` since the last final. Volatile results carry
    /// no per-token timing, so without this the next volatile would merge them back into one line.
    private var settled: [String] = []
    private var translations: [String: String] = [:]
    private var inFlight: Set<String> = []

    public init() {}

    /// Applies a recognizer event.
    public mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let tokens):
            var remainder = Segmenter.characters(tokens)
            if !settled.isEmpty {
                if let rest = Self.dropPrefix(settled.joined(), from: remainder) {
                    remainder = rest
                } else {
                    settled = [] // the recognizer revised settled text; re-split everything
                }
            }
            let (segments, tail) = segmenter.split(remainder, isFinal: false)
            replaceProvisional(with: settled + segments, isFinal: false)
            volatile = tail
            if tail.isEmpty { draftTranslation = nil }
        case .final(let tokens):
            let (segments, _) = segmenter.split(tokens, isFinal: true)
            replaceProvisional(with: segments, isFinal: true)
            finalCount = lines.count
            settled = []
            volatile = ""
            draftTranslation = nil
        }
    }

    /// Treats the in-progress segment as complete, e.g. after the speaker has been silent a while
    /// but the recognizer hasn't finalized yet. Locks all current provisional lines in place.
    public mutating func settleTail() {
        guard !volatile.isEmpty else { return }
        lines.append(Line(id: lines.count, source: volatile, translation: translations[volatile], isFinal: false))
        settled = lines.dropFirst(finalCount).map(\.source)
        volatile = ""
        draftTranslation = nil
    }

    /// The tokens after `prefix`, ignoring whitespace (segments are trimmed), or nil if they don't start with it.
    static func dropPrefix(_ prefix: String, from tokens: [Token]) -> [Token]? {
        var expected = prefix.filter { !$0.isWhitespace }.makeIterator()
        var next = expected.next()
        var index = 0
        while let character = next {
            guard index < tokens.count else { return nil }
            let text = tokens[index].text
            index += 1
            if text.allSatisfy(\.isWhitespace) { continue }
            guard text == String(character) else { return nil }
            next = expected.next()
        }
        return Array(tokens[index...])
    }

    /// Lines with no translation and none in flight.
    public var untranslated: [Line] {
        lines.filter { $0.translation == nil && !inFlight.contains($0.source) }
    }

    public mutating func beginTranslation(forSource source: String) {
        inFlight.insert(source)
    }

    public mutating func setTranslation(_ translation: String, forSource source: String) {
        inFlight.remove(source)
        translations[source] = translation
        for index in lines.indices where lines[index].source == source {
            lines[index].translation = translation
        }
    }

    /// Lets a failed line be requested again on the next event.
    public mutating func translationFailed(forSource source: String) {
        inFlight.remove(source)
    }

    /// Ignored if the in-progress text has since completed or been cleared.
    public mutating func setDraftTranslation(_ translation: String) {
        guard !volatile.isEmpty else { return }
        draftTranslation = translation
    }

    /// Up to `limit` translated lines immediately before `id`, oldest first.
    public func context(before id: Line.ID, limit: Int) -> [TranslatedLine] {
        lines
            .filter { $0.id < id }
            .compactMap { line in line.translation.map { TranslatedLine(source: line.source, translation: $0) } }
            .suffix(limit)
    }

    public func line(_ id: Line.ID) -> Line? {
        lines.first { $0.id == id }
    }

    private mutating func replaceProvisional(with segments: [String], isFinal: Bool) {
        lines = Array(lines.prefix(finalCount)) + segments.enumerated().map { offset, segment in
            Line(id: finalCount + offset, source: segment, translation: translations[segment], isFinal: isFinal)
        }
    }

}
