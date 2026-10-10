import Foundation

public struct Line: Identifiable, Sendable, Equatable {
    /// Position in the transcript; stable while a provisional segment keeps its place.
    public let id: Int
    public let source: String
    public var translation: String?
    /// False while the segment is still part of the recognizer's in-progress result and may be revised.
    public var isFinal: Bool
    /// Where the line was spoken, in seconds since the session began. Exact for final results;
    /// estimated to about a second for in-progress ones (see `LiveTranscriber`).
    public var start: TimeInterval = 0
    public var end: TimeInterval = 0
    /// Diarized speaker slot, set when the line becomes a caption.
    public var speaker: Int?
}

/// The running transcript, split into segments.
///
/// Apple's recognizer can go 10+ seconds between final results, so segments that are already
/// complete inside the volatile result (ended by punctuation or a pause, see `Segmenter`) are
/// surfaced as provisional lines right away. A line is shown as a caption once translated and
/// is then locked: later results never change it. Translations are cached by segment text, so a
/// provisional line that survives into the final isn't translated twice.
///
/// Every update touches only the lines that can still change (from `mutableStart` on), so the
/// cost per recognizer event doesn't grow with the length of the session.
///
/// Pure state so the event handling can be tested without audio or models.
public struct Transcript: Sendable {
    /// Captions (`lines[..<shownCount]`), then lines waiting for translation, then provisional lines.
    public private(set) var lines: [Line] = []
    /// The segment still being spoken.
    public var volatile: String { tail?.text ?? "" }
    private var tail: Segment?
    /// Rough translation of (a recent snapshot of) `volatile`, when drafts are enabled.
    public private(set) var draftTranslation: String?
    /// How many leading lines are captions: translated, in order, never changing again.
    public private(set) var shownCount = 0

    public var segmenter = Segmenter()

    /// Lines before this are final (from earlier recognizer results).
    private var finalCount = 0
    /// Lines of the current recognizer result that must not change any more: shown captions and
    /// lines settled after a pause. Later results — revisions, and the final with its own
    /// segmentation — only affect the text after them.
    private var locked: [Segment] = []
    private var draftSource = ""
    private var translations: [String: String] = [:]
    private var inFlight: Set<String> = []

    public init() {}

    /// Index of the first line that can still change in any way.
    public var mutableStart: Int { min(finalCount, shownCount) }

    public var shownLines: ArraySlice<Line> { lines[..<shownCount] }

    /// Recognized text not yet shown as a caption: lines awaiting translation plus the segment
    /// still being spoken.
    public var pendingText: String {
        (lines[shownCount...].map(\.source) + [volatile]).joined()
    }

    /// Lines with no translation and none in flight.
    public var untranslated: [Line] {
        lines[shownCount...].filter { $0.translation == nil && !inFlight.contains($0.source) }
    }

    public func line(_ id: Line.ID) -> Line? {
        lines.indices.contains(id) ? lines[id] : nil
    }

    // MARK: - Recognizer events

    public mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let tokens):
            let (segments, tail) = segmenter.split(unlocked(tokens), isFinal: false)
            replaceCurrentResult(with: locked + segments, isFinal: false)
            self.tail = tail
        case .final(let tokens):
            let (segments, _) = segmenter.split(unlocked(tokens), isFinal: true)
            replaceCurrentResult(with: locked + segments, isFinal: true)
            finalCount = lines.count
            locked = []
            tail = nil
        }
        dropStaleDraft()
    }

    /// Treats the in-progress segment as complete, e.g. after the speaker has been silent a while
    /// but the recognizer hasn't finalized yet. Locks all lines of the current result.
    public mutating func settleTail() {
        guard let tail else { return }
        lines.append(Line(id: lines.count, source: tail.text, translation: translations[tail.text], isFinal: false,
                          start: tail.start, end: tail.end))
        locked = lines[finalCount...].map(Self.segment)
        self.tail = nil
        dropStaleDraft()
        advanceShown()
    }

    // MARK: - Translation

    public mutating func beginTranslation(forSource source: String) {
        inFlight.insert(source)
    }

    public mutating func setTranslation(_ translation: String, forSource source: String) {
        inFlight.remove(source)
        translations[source] = translation
        var lastMatch: Int?
        for index in lines.indices.dropFirst(shownCount) where lines[index].source == source {
            lines[index].translation = translation
            lastMatch = index
        }
        // A line about to be shown gets locked, along with everything before it in this result.
        if let index = lastMatch, index >= finalCount, index - finalCount + 1 > locked.count {
            locked = lines[finalCount...index].map(Self.segment)
        }
        advanceShown()
    }

    /// Lets a failed line be requested again on the next event.
    public mutating func translationFailed(forSource source: String) {
        inFlight.remove(source)
    }

    /// Records a draft translation of `source`, a snapshot of the in-progress text. Ignored if that
    /// text has since been completed or replaced.
    public mutating func setDraftTranslation(_ translation: String, forSource source: String) {
        guard !volatile.isEmpty, Self.continues(volatile, from: source) else { return }
        draftTranslation = translation
        draftSource = source
    }

    /// Up to `limit` translated lines immediately before `id`, oldest first.
    public func context(before id: Line.ID, limit: Int) -> [TranslatedLine] {
        var result: [TranslatedLine] = []
        var index = min(id, lines.count) - 1
        while index >= 0, result.count < limit {
            if let translation = lines[index].translation {
                result.append(TranslatedLine(source: lines[index].source, translation: translation))
            }
            index -= 1
        }
        return result.reversed()
    }

    // MARK: - Internals

    /// Replaces the lines of the current recognizer result, in place.
    private mutating func replaceCurrentResult(with segments: [Segment], isFinal: Bool) {
        lines.removeSubrange(finalCount...)
        for (offset, segment) in segments.enumerated() {
            lines.append(Line(id: finalCount + offset, source: segment.text, translation: translations[segment.text],
                              isFinal: isFinal, start: segment.start, end: segment.end))
        }
        if shownCount > lines.count {
            // Shown captions are locked, so this shouldn't happen; if it does, the UI loses lines.
            Trace.shared.event("seg.shown_lost", ["shown": shownCount, "lines": lines.count])
            shownCount = lines.count
        }
        advanceShown()
    }

    private mutating func advanceShown() {
        while shownCount < lines.count, lines[shownCount].translation != nil {
            shownCount += 1
        }
        // Whatever is shown must be locked, including lines shown straight from the cache.
        if shownCount - finalCount > locked.count {
            locked = lines[finalCount..<shownCount].map(Self.segment)
        }
    }

    private static func segment(_ line: Line) -> Segment {
        Segment(text: line.source, start: line.start, end: line.end)
    }

    /// Drops the draft once the in-progress text it was made from has completed or been replaced.
    private mutating func dropStaleDraft() {
        guard draftTranslation != nil, volatile.isEmpty || !Self.continues(volatile, from: draftSource) else { return }
        draftTranslation = nil
        draftSource = ""
    }

    /// Whether `text` is (a revision or extension of) the speech `earlier` was taken from.
    static func continues(_ text: String, from earlier: String) -> Bool {
        let probe = earlier.prefix(min(4, earlier.count))
        return !probe.isEmpty && text.hasPrefix(probe)
    }

    /// The tokens after the locked lines.
    private func unlocked(_ tokens: [Token]) -> [Token] {
        let characters = Segmenter.characters(tokens)
        guard !locked.isEmpty else { return characters }
        let prefix = locked.map(\.text).joined()
        if let rest = Self.dropPrefix(prefix, from: characters) { return rest }
        // The recognizer revised text under the locked captions. Revisions are usually earlier in
        // the segment, so find where the locked text *ends* in the new hypothesis and continue
        // after that; only if its ending can't be found, skip the same number of characters.
        let (rest, method) = Self.dropThroughEnding(of: prefix, from: characters)
            .map { ($0, "ending") } ?? (Self.drop(count: prefix.filter { !$0.isWhitespace }.count, from: characters), "count")
        Trace.shared.event("seg.realign", [
            "method": method,
            "locked": prefix,
            "revised": Segmenter.text(Array(characters.prefix(characters.count - rest.count))),
        ])
        return rest
    }

    /// The tokens after the occurrence of `prefix`'s last few characters nearest to where `prefix`
    /// would end, or nil if no such occurrence exists.
    static func dropThroughEnding(of prefix: String, from tokens: [Token]) -> [Token]? {
        let target = Array(prefix.filter { !$0.isWhitespace })
        // Non-whitespace characters of the new hypothesis, with their token indices.
        let indexed = tokens.enumerated().compactMap { index, token -> (Character, Int)? in
            guard let character = token.text.first, !token.text.allSatisfy(\.isWhitespace) else { return nil }
            return (character, index)
        }
        let text = indexed.map(\.0)
        for length in [8, 5, 3] where target.count >= length {
            let ending = Array(target.suffix(length))
            let matches = text.indices.dropLast(length - 1).filter { Array(text[$0..<$0 + length]) == ending }
            guard let start = matches.min(by: { abs($0 + length - target.count) < abs($1 + length - target.count) })
            else { continue }
            return Array(tokens[(indexed[start + length - 1].1 + 1)...])
        }
        return nil
    }

    static func drop(count: Int, from tokens: [Token]) -> [Token] {
        var remaining = count
        var index = 0
        while remaining > 0, index < tokens.count {
            if !tokens[index].text.allSatisfy(\.isWhitespace) { remaining -= 1 }
            index += 1
        }
        return Array(tokens[index...])
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
}
