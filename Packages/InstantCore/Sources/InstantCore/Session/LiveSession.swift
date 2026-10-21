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

    /// Full pipeline state. Not observed directly: it changes several times a second, and views
    /// observing it would all re-render. Views use `captions`, `pendingText` and `draftTranslation`.
    @ObservationIgnored public private(set) var transcript = Transcript() {
        didSet { publish() }
    }
    /// Shown captions, append-only: a caption never changes once added.
    public private(set) var captions: [Line] = []
    /// Recognized text not yet a caption (Japanese only).
    public private(set) var pendingText = ""
    public private(set) var draftTranslation: String?
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { Trace.shared.event("session.status", ["status": "\(status)"]) } }
    }
    public var sourceLocale: Locale
    public var targetLanguage: Locale.Language
    public var input: Input = .microphone
    /// What the running session is listening to, for display ("麥克風", "Mac 聲音", a file name).
    public private(set) var sourceDescription = ""

    /// Non-nil while the translation pair needs downloading. The UI attaches
    /// `.translationTask(_:)` with it (the system consent sheet needs a view), calls
    /// `prepareTranslation()`, then `translationDownloadFinished()`.
    public private(set) var translationDownload: TranslationSession.Configuration?

    /// Tell speakers apart (FluidAudio Sortformer, up to 4). The model downloads on first use.
    public var speakerDiarizationEnabled = true
    /// Names the user gave diarized speaker slots ("田中"); unnamed ones show as A, B, C, D.
    public var speakerNames: [Int: String] = [:]
    /// Speaker slots in order of first appearance, so unnamed speakers read A, B, C… as they turn
    /// up (Sortformer's slot numbers can skip).
    public private(set) var speakerOrder: [Int] = []
    /// How long a finished line may wait for diarization to reach it before showing without a speaker.
    public var speakerWait: Duration = .milliseconds(1200)
    /// Download progress (0…1) of the speaker model while it's downloading (first use only); nil otherwise.
    public private(set) var speakerModelDownload: Double?
    /// Approximate download size of the speaker model, for progress text.
    public static let speakerModelMegabytes = 240
    /// When the running session started listening; nil when not running.
    public private(set) var startedAt: Date?

    /// Keep the audio, so it can be played back with the captions after stopping.
    public var recordingEnabled = true
    /// The last session's audio, once it has stopped. Captions' times are positions in it.
    public struct Recording: Equatable, Sendable {
        public let url: URL
        public let duration: TimeInterval
        /// When listening started.
        public let started: Date
    }
    public private(set) var recording: Recording?

    /// How many earlier lines are passed to context-aware translators.
    public var contextLimit = 6
    /// Also translate the segment still being spoken, re-translating as it grows. Off: a line is
    /// translated once it's segmented (~70ms with `.lowLatency`), so captions appear complete and
    /// never change under the reader, and half a Japanese sentence often translates misleadingly.
    public var draftTranslationsEnabled = false
    /// Minimum spacing between draft translations of in-progress speech.
    public var draftInterval: Duration = .milliseconds(500)
    /// With no new recognition for this long, the in-progress segment is treated as complete.
    /// Longer than the recognizer's ~1s update cadence so ongoing speech isn't cut.
    public var settleDelay: Duration = .milliseconds(1500)
    /// A provisional line is translated only after its text has stayed the same this long; the
    /// recognizer often revises the last second or two. Final lines are translated immediately.
    public var stableDelay: Duration = .milliseconds(400)

    private var audioSource: AudioSource?
    private var transcriber: SpeechRecognizer?
    private var translator: Translator?
    private var eventsTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var stableTimers: [String: Task<Void, Never>] = [:]
    private var stallProbe: Task<Void, Never>?
    private var diarizer: SpeakerSource?
    private var audioTasks: [Task<Void, Never>] = []
    /// When each finished line started waiting for diarization, by line id.
    private var speakerWaitStarted: [Line.ID: ContinuousClock.Instant] = [:]
    private var publishRetry: Task<Void, Never>?
    private var handleTimes: [Double] = []
    /// Keeps macOS from App-Napping us while the user watches another app: in the background,
    /// translation round-trips went from ~70ms to ~1.3s without it.
    private var activity: NSObjectProtocol?
    private var downloadContinuation: CheckedContinuation<Void, Never>?
    /// Resumed with the loaded diarizer, or nil when skipped or cancelled.
    private var speakerLoadContinuation: CheckedContinuation<SpeakerDiarizer?, Never>?
    private var startCancelled = false
    private var recorderTask: Task<Double, Never>?
    private var recordingURL: URL?

    /// Who recognizes speech. Cloud engines need `apiKey(engine)` to return a key.
    public var engine: SpeechEngine = .apple
    /// The user's key for a cloud engine, read when a session starts.
    public var apiKey: (SpeechEngine) -> String? = { _ in nil }

    public init(sourceLocale: Locale = Locale(identifier: "ja-JP"),
                targetLanguage: Locale.Language = Locale.Language(identifier: "zh-Hant-TW")) {
        self.sourceLocale = sourceLocale
        self.targetLanguage = targetLanguage
    }

    /// Starts a session. `audioSource` overrides `input` (used for file playback in the lab).
    public func start(audioSource override: AudioSource? = nil) async {
        guard !status.isActive else { return }
        // A recorded session's captions belong to its recording: start afresh.
        if recording != nil { clear() }
        diarizer = nil
        speakerOrder = []
        startCancelled = false
        Trace.shared.begin()
        Trace.shared.event("session.start", [
            "source": sourceLocale.identifier(.bcp47),
            "target": targetLanguage.maximalIdentifier,
            "input": override.map { "\(type(of: $0))" } ?? input.rawValue,
            "drafts": draftTranslationsEnabled,
            "engine": engine.rawValue,
        ])
        do {
            status = .preparing("準備翻譯…")
            translator = try await makeTranslator()

            try checkCancelled()

            let engine = engine
            let key = engine.isCloud ? apiKey(engine) ?? "" : ""
            if engine.isCloud && key.isEmpty { throw SessionError.missingAPIKey(engine) }
            let cloud = engine.isCloud
                ? CloudTranscriber(engine: engine, apiKey: key, locale: sourceLocale, diarize: speakerDiarizationEnabled)
                : nil
            if let speakers = cloud?.speakers {
                // The service labels speakers itself; no on-device model.
                diarizer = speakers
            } else if speakerDiarizationEnabled {
                status = .preparing("準備說話者辨識…")
                diarizer = await loadDiarizer()
                speakerModelDownload = nil
            }

            try checkCancelled()
            status = .preparing("開啟音訊…")
            let source = override ?? makeAudioSource()
            audioSource = source
            sourceDescription = (source as? FileAudioSource)?.name ?? (input == .microphone ? "麥克風" : "Mac 聲音")
            var chunks = try await source.start()
            // Recognition, diarization and the recorder each get every chunk, in parallel.
            var consumers: [AsyncStream<AudioChunk>.Continuation] = []
            if let diarizer = diarizer as? SpeakerDiarizer {
                let (forDiarization, toDiarization) = AsyncStream<AudioChunk>.makeStream()
                consumers.append(toDiarization)
                audioTasks.append(Task.detached(priority: .userInitiated) { await diarizer.run(forDiarization) })
            }
            if recordingEnabled {
                let (forRecorder, toRecorder) = AsyncStream<AudioChunk>.makeStream()
                consumers.append(toRecorder)
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "Instant recordings", directoryHint: .isDirectory)
                    .appending(path: "\(UUID().uuidString).m4a")
                let recorder = AudioRecorder(url: url)
                recordingURL = url
                recorderTask = Task.detached(priority: .utility) { await recorder.run(forRecorder) }
            }
            if !consumers.isEmpty {
                let (forRecognition, toRecognition) = AsyncStream<AudioChunk>.makeStream()
                consumers.append(toRecognition)
                let input = chunks
                audioTasks.append(Task.detached(priority: .userInitiated) { [consumers] in
                    for await chunk in input {
                        for consumer in consumers { consumer.yield(chunk) }
                    }
                    for consumer in consumers { consumer.finish() }
                })
                chunks = forRecognition
            }

            status = .preparing(engine.isCloud ? "連線到 \(engine.name)…" : "準備語音辨識…")
            let transcriber: SpeechRecognizer = cloud ?? LiveTranscriber(locale: sourceLocale)
            self.transcriber = transcriber
            let events = try await transcriber.start(audio: chunks)
            try checkCancelled()

            status = .running
            startedAt = .now
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Live captions and translation")
            stallProbe = Task { await Self.probeMainThreadStalls() }
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
            status = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    /// Loads the speaker model; returns early with nil if the user skips speakers for this
    /// session (the download keeps going in the background, so it's ready next time).
    private func loadDiarizer() async -> SpeakerDiarizer? {
        await withCheckedContinuation { continuation in
            speakerLoadContinuation = continuation
            Task {
                let loaded: SpeakerDiarizer?
                do {
                    loaded = try await SpeakerDiarizer.load { fraction in
                        // Only reported while downloading (first use, ~240 MB).
                        Task { @MainActor [self] in
                            guard fraction < 1, speakerLoadContinuation != nil else { return }
                            speakerModelDownload = fraction
                            status = .preparing("下載說話者辨識模型 \(Int(fraction * 100))%（只有第一次）")
                        }
                    }
                } catch {
                    // Captions still work without speakers.
                    Trace.shared.event("spk.error", ["error": "\(error)", "stage": "load"])
                    loaded = nil
                }
                finishSpeakerLoad(loaded)
            }
        }
    }

    private func finishSpeakerLoad(_ diarizer: SpeakerDiarizer?) {
        speakerLoadContinuation?.resume(returning: diarizer)
        speakerLoadContinuation = nil
    }

    /// Starts this session without telling speakers apart, instead of waiting for the speaker
    /// model to download. `speakerDiarizationEnabled` is unchanged, so the next session uses it.
    public func skipSpeakerDiarization() {
        guard speakerLoadContinuation != nil else { return }
        Trace.shared.event("spk.skip", ["download": speakerModelDownload ?? -1])
        speakerModelDownload = nil
        finishSpeakerLoad(nil)
    }

    /// Abandons a start that's still preparing (e.g. downloading the speaker model).
    public func cancelStart() {
        guard case .preparing = status else { return }
        startCancelled = true
        speakerModelDownload = nil
        finishSpeakerLoad(nil)
        translationDownloadFinished()
    }

    private func checkCancelled() throws {
        if startCancelled { throw CancellationError() }
    }

    /// Speaker slots heard in the latest audio, for a "speaking now" indicator. Not observed:
    /// poll it (it changes every 80ms).
    public var speakingNow: [Int] {
        status == .running ? diarizer?.speakingNow ?? [] : []
    }

    /// Stops capture; already-heard speech is still recognized and translated.
    public func stop() async {
        audioSource?.stop()
        await transcriber?.stop()
        await eventsTask?.value
    }

    /// Input level 0…1 for a meter; 0 when not listening.
    public var audioLevel: Float { transcriber?.level.value ?? 0 }

    public func clear() {
        guard !status.isActive else { return }
        discardRecording()
        transcript = Transcript()
        captions = []
        speakerNames = [:]
        speakerOrder = []
        status = .idle
    }

    /// Deletes the last session's audio (after it has been saved elsewhere, or isn't wanted).
    public func discardRecording() {
        if let recording { try? FileManager.default.removeItem(at: recording.url) }
        recording = nil
    }

    private func schedulePublishRetry() {
        guard publishRetry == nil else { return }
        publishRetry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            publishRetry = nil
            publish()
        }
    }

    #if DEBUG
    /// Debug-only: puts the session in a canned listening state (captions with speakers, speech in
    /// progress) without running the pipeline, so the UI can be checked where speech recognition
    /// can't run, such as the Simulator.
    public func showDemoState(captions demo: [(speaker: Int, source: String, translation: String)],
                              pending: String, draft: String?, elapsed: TimeInterval) {
        captions = demo.enumerated().map { index, line in
            var caption = Line(id: index, source: line.source, translation: line.translation, isFinal: true, speaker: line.speaker)
            // Spread over the elapsed time, leaving the last stretch for the pending line.
            caption.start = elapsed * 0.9 * Double(index) / Double(demo.count)
            return caption
        }
        speakerOrder = demo.map(\.speaker).reduce(into: []) { order, slot in if !order.contains(slot) { order.append(slot) } }
        pendingText = pending
        draftTranslation = draft
        sourceDescription = input == .microphone ? "麥克風" : "Mac 聲音"
        startedAt = .now - elapsed
        status = .running
    }
    #endif

    /// Display name for a diarized speaker slot.
    public func speakerName(_ speaker: Int) -> String {
        speakerNames[speaker] ?? String(UnicodeScalar(UInt8(65 + (speakerOrder.firstIndex(of: speaker) ?? speaker))))
    }

    /// Copies what views show out of `transcript`, assigning only what changed so observers of
    /// one property aren't invalidated by changes to another.
    private func publish() {
        while captions.count < transcript.shownCount {
            var line = transcript.lines[captions.count]
            if let diarizer {
                // Let diarization (≈1s behind) reach the end of the line, so its speaker is known
                // when it appears instead of popping in later.
                let now = ContinuousClock.now
                let waitStarted = speakerWaitStarted[line.id, default: now]
                speakerWaitStarted[line.id] = waitStarted
                let waited = now - waitStarted
                if diarizer.coveredUntil < line.end, waited < speakerWait {
                    schedulePublishRetry()
                    break
                }
                let attribution = diarizer.attribute(start: line.start, end: line.end)
                line.speaker = attribution.speaker
                if let speaker = attribution.speaker, !speakerOrder.contains(speaker) { speakerOrder.append(speaker) }
                speakerWaitStarted[line.id] = nil
                Trace.shared.event("spk.assign", [
                    "id": line.id,
                    "source": line.source,
                    "start": line.start.rounded(toPlaces: 2),
                    "end": line.end.rounded(toPlaces: 2),
                    "speaker": attribution.speaker ?? -1,
                    "share": attribution.share.rounded(toPlaces: 2),
                    "wait_ms": Int(Trace.seconds(waited) * 1000),
                    "covered": diarizer.coveredUntil >= line.end,
                ])
            }
            captions.append(line)
        }
        let pending = transcript.pendingText
        if pending != pendingText { pendingText = pending }
        if transcript.draftTranslation != draftTranslation { draftTranslation = transcript.draftTranslation }
    }

    public func translationDownloadFinished() {
        downloadContinuation?.resume()
        downloadContinuation = nil
    }

    // MARK: - Pipeline

    private func handle(_ event: TranscriptEvent) {
        let started = ContinuousClock.now
        defer {
            // Main-actor time spent per recognizer event; grows if anything is O(transcript length).
            handleTimes.append(Trace.seconds(ContinuousClock.now - started) * 1000)
            if handleTimes.count == 50 {
                let sorted = handleTimes.sorted()
                Trace.shared.event("main.handle", [
                    "lines": transcript.lines.count,
                    "p50_ms": sorted[25].rounded(toPlaces: 2),
                    "max_ms": sorted[49].rounded(toPlaces: 2),
                ])
                handleTimes.removeAll(keepingCapacity: true)
            }
        }
        let start = transcript.mutableStart
        let before = Array(transcript.lines[start...])
        transcript.apply(event)
        traceSegmentation(before: before, from: start, cause: { if case .final = event { "final" } else { "volatile" } }())
        scheduleTranslations()
        settleTask?.cancel()
        guard !transcript.volatile.isEmpty else { return }
        settleTask = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled, let self else { return }
            let start = transcript.mutableStart
            let before = Array(transcript.lines[start...])
            transcript.settleTail()
            traceSegmentation(before: before, from: start, cause: "settle")
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
        let present = Set(transcript.lines[transcript.shownCount...].map(\.source))
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
                    "stale": !transcript.lines[transcript.mutableStart...].contains { $0.source == line.source }
                        && !transcript.shownLines.suffix(8).contains { $0.source == line.source },
                ])
            } catch {
                transcript.translationFailed(forSource: line.source)
                Trace.shared.event("mt.error", ["id": lineID, "source": line.source, "error": "\(error)"])
            }
        }
    }

    /// Every 100ms, checks how late the main actor gets to run. Everything the UI shows (and every
    /// translation result) goes through it, so stalls here look like slow translation.
    private static func probeMainThreadStalls() async {
        let interval = 0.1
        var worst = 0.0
        var lastReport = Trace.shared.elapsed
        while !Task.isCancelled {
            let before = Trace.shared.elapsed
            try? await Task.sleep(for: .milliseconds(100))
            let late = Trace.shared.elapsed - before - interval
            worst = max(worst, late)
            if late > 0.25 { Trace.shared.event("main.stall", ["ms": Int(late * 1000)]) }
            if Trace.shared.elapsed - lastReport >= 5 {
                Trace.shared.event("main.load", ["worst_ms": Int(worst * 1000)])
                worst = 0
                lastReport = Trace.shared.elapsed
            }
        }
    }

    /// Records which lines appeared, changed or disappeared, and the remaining in-progress text.
    private func traceSegmentation(before: [Line], from start: Int, cause: String) {
        let after = transcript.lines[min(start, transcript.lines.count)...]
        let added = after.filter { line in !before.contains { $0.id == line.id } }
        let changed = after.filter { line in before.contains { $0.id == line.id && ($0.source != line.source || $0.isFinal != line.isFinal) } }
        let removed = before.filter { line in !after.contains { $0.id == line.id } }
        guard !added.isEmpty || !changed.isEmpty || !removed.isEmpty || cause == "final" else { return }
        // Captions already on screen (translated) must never change; count any that did.
        let shown = Set(before.filter { $0.translation != nil }.map(\.id))
        let rewritten = changed.filter { line in
            shown.contains(line.id) && before.first { $0.id == line.id }?.source != line.source
        }.map(\.id) + removed.filter { shown.contains($0.id) }.map(\.id)
        if !rewritten.isEmpty { Trace.shared.event("seg.rewrite", ["ids": rewritten, "cause": cause]) }
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
                    transcript.setDraftTranslation(draft, forSource: snapshot)
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
        // The recorder finishes with the audio (stopped above); wait for it to close the file.
        if let recorderTask, let url = recordingURL {
            let seconds = await recorderTask.value
            if seconds >= 1 {
                recording = Recording(url: url, duration: seconds, started: startedAt ?? .now)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        recorderTask = nil
        recordingURL = nil
        draftTask?.cancel()
        draftTask = nil
        settleTask?.cancel()
        settleTask = nil
        stableTimers.values.forEach { $0.cancel() }
        stableTimers = [:]
        stallProbe?.cancel()
        stallProbe = nil
        audioTasks.forEach { $0.cancel() }
        audioTasks = []
        // Keep `diarizer`: translations still landing after the audio ends need it for speakers.
        publishRetry?.cancel()
        publishRetry = nil
        speakerWaitStarted = [:]
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        startedAt = nil
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
            try checkCancelled()
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
    case missingAPIKey(SpeechEngine)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let engine): "請先到設定輸入 \(engine.name) 的 API key。"
        case .translationNotInstalled: "翻譯語言包沒有下載完成。"
        case .translationUnsupported: "Apple 翻譯不支援這組語言。"
        }
    }
}
