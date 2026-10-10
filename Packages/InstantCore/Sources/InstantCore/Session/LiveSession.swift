import Foundation
import Observation
@preconcurrency import Translation

/// Wires audio → recognition → translation and publishes the transcript for the UI.
@MainActor
@Observable
public final class LiveSession {
    public enum Input: String, CaseIterable, Identifiable, Sendable {
        case microphone
        case systemAudio

        public var id: String { rawValue }

        public static var available: [Input] {
            #if os(macOS)
            allCases
            #else
            [.microphone]
            #endif
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case preparing(String)
        case running
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .preparing, .running: true
            case .idle, .failed: false
            }
        }
    }

    public private(set) var transcript = Transcript()
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { Trace.shared.event("session.status", ["status": "\(status)"]) } }
    }
    public var sourceLocale: Locale
    public var targetLanguage: Locale.Language
    public var input: Input = .microphone

    /// Non-nil while the translation pair needs downloading. The UI attaches
    /// `.translationTask(_:)` with it (the system consent sheet needs a view), calls
    /// `prepareTranslation()`, then `translationDownloadFinished()`.
    public private(set) var translationDownload: TranslationSession.Configuration?

    /// How many earlier lines are passed to context-aware translators.
    public var contextLimit = 6
    /// Also translate the segment still being spoken, re-translating as it grows, so Chinese
    /// follows the Japanese live instead of waiting for the segment to end. Cheap with the
    /// on-device Apple translator (~50ms, free); a future LLM translator should only do lines.
    public var draftTranslationsEnabled = true
    /// Minimum spacing between draft translations of in-progress speech.
    public var draftInterval: Duration = .milliseconds(500)
    /// With no new recognition for this long, the in-progress segment is treated as complete.
    /// Longer than the recognizer's ~1s update cadence so ongoing speech isn't cut.
    public var settleDelay: Duration = .milliseconds(1500)
    /// A provisional line is translated only after its text has stayed the same this long; the
    /// recognizer often revises the last second or two. Final lines are translated immediately.
    public var stableDelay: Duration = .milliseconds(400)

    private var audioSource: AudioSource?
    private var transcriber: LiveTranscriber?
    private var translator: Translator?
    private var eventsTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var stableTimers: [String: Task<Void, Never>] = [:]
    private var downloadContinuation: CheckedContinuation<Void, Never>?

    public init(sourceLocale: Locale = Locale(identifier: "ja-JP"),
                targetLanguage: Locale.Language = Locale.Language(identifier: "zh-Hant-TW")) {
        self.sourceLocale = sourceLocale
        self.targetLanguage = targetLanguage
    }

    /// Starts a session. `audioSource` overrides `input` (used for file playback in the lab).
    public func start(audioSource override: AudioSource? = nil) async {
        guard !status.isActive else { return }
        Trace.shared.begin()
        Trace.shared.event("session.start", [
            "source": sourceLocale.identifier(.bcp47),
            "target": targetLanguage.maximalIdentifier,
            "input": override.map { "\(type(of: $0))" } ?? input.rawValue,
            "drafts": draftTranslationsEnabled,
        ])
        do {
            status = .preparing("準備翻譯…")
            translator = try await makeTranslator()

            status = .preparing("開啟音訊…")
            let source = override ?? makeAudioSource()
            audioSource = source
            let chunks = try await source.start()

            status = .preparing("準備語音辨識…")
            let transcriber = LiveTranscriber(locale: sourceLocale)
            self.transcriber = transcriber
            let events = try await transcriber.start(audio: chunks)

            status = .running
            eventsTask = Task { [weak self] in
                do {
                    for try await event in events { self?.handle(event) }
                    self?.finish(nil)
                } catch {
                    self?.finish(error)
                }
            }
        } catch {
            await teardown()
            status = .failed(error.localizedDescription)
        }
    }

    /// Stops capture; already-heard speech is still recognized and translated.
    public func stop() async {
        audioSource?.stop()
        await transcriber?.stop()
        await eventsTask?.value
    }

    public func clear() {
        guard !status.isActive else { return }
        transcript = Transcript()
        status = .idle
    }

    public func translationDownloadFinished() {
        downloadContinuation?.resume()
        downloadContinuation = nil
    }

    // MARK: - Pipeline

    private func handle(_ event: TranscriptEvent) {
        let before = transcript.lines
        transcript.apply(event)
        traceSegmentation(before: before, cause: { if case .final = event { "final" } else { "volatile" } }())
        scheduleTranslations()
        settleTask?.cancel()
        guard !transcript.volatile.isEmpty else { return }
        settleTask = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled, let self else { return }
            let before = transcript.lines
            transcript.settleTail()
            traceSegmentation(before: before, cause: "settle")
            scheduleTranslations()
        }
        if draftTranslationsEnabled, draftTask == nil {
            draftTask = Task { [weak self] in await self?.runDrafts() }
        }
    }

    /// Final lines are translated now; provisional ones once they've stopped changing.
    private func scheduleTranslations() {
        for line in transcript.untranslated {
            if line.isFinal {
                stableTimers.removeValue(forKey: line.source)?.cancel()
                translate(lineID: line.id)
            } else if stableTimers[line.source] == nil {
                stableTimers[line.source] = Task { [weak self, stableDelay, source = line.source] in
                    try? await Task.sleep(for: stableDelay)
                    guard !Task.isCancelled, let self else { return }
                    stableTimers[source] = nil
                    if let current = transcript.untranslated.first(where: { $0.source == source }) {
                        translate(lineID: current.id)
                    }
                }
            }
        }
        // Drop timers for text the recognizer has since revised away.
        let present = Set(transcript.lines.map(\.source))
        for (source, timer) in stableTimers where !present.contains(source) {
            timer.cancel()
            stableTimers[source] = nil
        }
    }

    private func translate(lineID: Line.ID) {
        guard let translator, let line = transcript.line(lineID) else { return }
        transcript.beginTranslation(forSource: line.source)
        let context = transcript.context(before: lineID, limit: contextLimit)
        Trace.shared.event("mt.request", ["id": lineID, "source": line.source, "context": context.count])
        let requested = Trace.shared.elapsed
        Task {
            do {
                let translation = try await translator.translate(line.source, context: context)
                transcript.setTranslation(translation, forSource: line.source)
                Trace.shared.event("mt.response", [
                    "id": lineID,
                    "source": line.source,
                    "translation": translation,
                    "ms": Int((Trace.shared.elapsed - requested) * 1000),
                    // The recognizer revised this line while it was being translated: wasted work.
                    "stale": !transcript.lines.contains { $0.source == line.source },
                ])
            } catch {
                transcript.translationFailed(forSource: line.source)
                Trace.shared.event("mt.error", ["id": lineID, "source": line.source, "error": "\(error)"])
            }
        }
    }

    /// Records which lines appeared, changed or disappeared, and the remaining in-progress text.
    private func traceSegmentation(before: [Line], cause: String) {
        let after = transcript.lines
        let added = after.filter { line in !before.contains { $0.id == line.id } }
        let changed = after.filter { line in before.contains { $0.id == line.id && ($0.source != line.source || $0.isFinal != line.isFinal) } }
        let removed = before.filter { line in !after.contains { $0.id == line.id } }
        guard !added.isEmpty || !changed.isEmpty || !removed.isEmpty || cause == "final" else { return }
        Trace.shared.event("seg.update", [
            "cause": cause,
            "added": added.map { ["id": $0.id, "source": $0.source, "final": $0.isFinal] as [String: any Sendable] },
            "changed": changed.map { ["id": $0.id, "source": $0.source, "final": $0.isFinal] as [String: any Sendable] },
            "removed": removed.map(\.id),
            "tail": transcript.volatile,
        ])
    }

    /// Translates the in-progress text at most every `draftInterval` until it commits.
    private func runDrafts() async {
        defer { draftTask = nil }
        var lastDrafted = ""
        while !Task.isCancelled, let translator {
            let snapshot = transcript.volatile
            if snapshot.isEmpty { return }
            if snapshot != lastDrafted {
                lastDrafted = snapshot
                let context = transcript.lines.last.map { transcript.context(before: $0.id + 1, limit: contextLimit) } ?? []
                let requested = Trace.shared.elapsed
                if let draft = try? await translator.translate(snapshot, context: context) {
                    transcript.setDraftTranslation(draft)
                    Trace.shared.event("mt.draft", [
                        "source": snapshot,
                        "translation": draft,
                        "ms": Int((Trace.shared.elapsed - requested) * 1000),
                        // The in-progress text moved on while translating.
                        "stale": transcript.volatile != snapshot,
                    ])
                }
            }
            try? await Task.sleep(for: draftInterval)
        }
    }

    private func finish(_ error: Error?) {
        Trace.shared.event("session.end", [
            "error": error.map { "\($0)" } ?? "",
            "lines": transcript.lines.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "final": $0.isFinal] as [String: any Sendable] },
        ])
        Task {
            await teardown()
            status = error.map { .failed($0.localizedDescription) } ?? .idle
        }
    }

    private func teardown() async {
        audioSource?.stop()
        audioSource = nil
        draftTask?.cancel()
        draftTask = nil
        settleTask?.cancel()
        settleTask = nil
        stableTimers.values.forEach { $0.cancel() }
        stableTimers = [:]
        await transcriber?.cancel()
        transcriber = nil
        eventsTask = nil
    }

    private func makeAudioSource() -> AudioSource {
        switch input {
        case .microphone:
            return MicrophoneSource()
        case .systemAudio:
            #if os(macOS)
            return SystemAudioSource()
            #else
            return MicrophoneSource()
            #endif
        }
    }

    private func makeTranslator() async throws -> Translator {
        let source = sourceLocale.language
        switch await AppleTranslator.status(from: source, to: targetLanguage) {
        case .installed:
            break
        case .supported:
            status = .preparing("下載翻譯語言包…")
            await withCheckedContinuation { continuation in
                downloadContinuation = continuation
                translationDownload = .init(source: source, target: targetLanguage)
            }
            translationDownload = nil
            guard await AppleTranslator.status(from: source, to: targetLanguage) == .installed else {
                throw SessionError.translationNotInstalled
            }
        case .unsupported:
            throw SessionError.translationUnsupported
        @unknown default:
            throw SessionError.translationUnsupported
        }
        return AppleTranslator(source: source, target: targetLanguage)
    }
}

public enum SessionError: LocalizedError {
    case translationNotInstalled
    case translationUnsupported

    public var errorDescription: String? {
        switch self {
        case .translationNotInstalled: "翻譯語言包沒有下載完成。"
        case .translationUnsupported: "Apple 翻譯不支援這組語言。"
        }
    }
}
