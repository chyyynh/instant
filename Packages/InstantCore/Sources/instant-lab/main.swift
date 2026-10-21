import CoreML
import FluidAudio
import Foundation
import InstantCore

// End-to-end runs of the live pipeline on real audio, played at real-time speed.
//
//   instant-lab run <audio> [--start s] [--duration s] [--source ja-JP] [--target zh-Hant-TW] [--trace file]
//                   [--engine apple|soniox|elevenLabs] [--ask question]
//   instant-lab report <trace.jsonl> [truth.json]
//   instant-lab reference <audio> --start s --duration s --out truth.json
//
// `reference` writes reference speaker turns for a clip using FluidAudio's offline VBx pipeline
// (whole-clip context, far more accurate than streaming) — a stand-in for hand-labeled truth.
//
// `run` writes a trace (default /tmp/instant-trace.jsonl) and prints the report. With --ask it then
// asks Claude about the transcript (needs ANTHROPIC_API_KEY), the way the app's Claude panel does.
// --engine soniox / elevenLabs recognizes in the cloud instead (needs SONIOX_API_KEY / ELEVENLABS_API_KEY).
// The app writes the same trace when launched with INSTANT_TRACE=<file>.

@MainActor
func run(_ args: [String]) async -> Int32 {
    var args = args
    func option(_ name: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
        defer { args.removeSubrange(i...i + 1) }
        return args[i + 1]
    }
    let source = option("--source", "ja-JP")
    let target = option("--target", "zh-Hant-TW")
    let startAt = TimeInterval(option("--start", "0")) ?? 0
    let duration = TimeInterval(option("--duration", "0")) ?? 0
    let tracePath = option("--trace", "/tmp/instant-trace.jsonl")
    let truthPath = option("--truth", "")
    let question = option("--ask", "")
    guard let engine = SpeechEngine(rawValue: option("--engine", "apple")) else { return usage() }
    let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    if !question.isEmpty && apiKey.isEmpty {
        print("--ask needs ANTHROPIC_API_KEY")
        return 2
    }
    guard let path = args.first else { return usage() }

    setenv("INSTANT_TRACE", tracePath, 1)
    let session = LiveSession(sourceLocale: Locale(identifier: source), targetLanguage: Locale.Language(identifier: target))
    session.engine = engine
    session.apiKey = { engine in
        let name = engine == .soniox ? "SONIOX_API_KEY" : "ELEVENLABS_API_KEY"
        return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }
    let watchdog = Task { @MainActor in
        while !Task.isCancelled {
            if session.translationDownload != nil {
                print("翻譯語言包未安裝：系統設定 › 一般 › 語言與地區 › 翻譯語言，下載後重試。")
                exit(1)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    print("▶︎ \(URL(fileURLWithPath: path).lastPathComponent) from \(Int(startAt))s\(duration > 0 ? " for \(Int(duration))s" : "") → \(tracePath)")
    await session.start(audioSource: FileAudioSource(url: URL(fileURLWithPath: path), startTime: startAt))
    if duration > 0 {
        try? await Task.sleep(for: .seconds(duration))
        await session.stop()
    }
    while session.status.isActive { try? await Task.sleep(for: .milliseconds(100)) }
    try? await Task.sleep(for: .seconds(2)) // let trailing translations land
    watchdog.cancel()
    Trace.shared.event("lab.done", [
        "status": "\(session.status)",
        "lines": session.transcript.lines.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "final": $0.isFinal] as [String: any Sendable] },
    ])
    report(tracePath, truth: truthPath.isEmpty ? nil : truthPath)
    if case .failed = session.status { return 1 }
    if !question.isEmpty { return await ask(question, about: session, client: ClaudeClient(apiKey: apiKey)) }
    return 0
}

@MainActor
func ask(_ question: String, about session: LiveSession, client: ClaudeClient) async -> Int32 {
    let assistant = Assistant()
    print("\n? \(question)")
    let asked = ContinuousClock.now
    var firstText: Duration?
    assistant.ask(question, captions: session.captions, pending: session.pendingText,
                  speakerName: { "說話者 \(session.speakerName($0))" }, client: client)
    var printed = 0
    while assistant.isResponding {
        let text = assistant.messages.last?.text ?? ""
        if text.count > printed {
            if firstText == nil { firstText = .now - asked }
            print(text.dropFirst(printed), terminator: "")
            fflush(stdout)
            printed = text.count
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    if let error = assistant.errorMessage {
        print("\n✗ \(error)")
        return 1
    }
    print(assistant.messages.last?.text.dropFirst(printed) ?? "")
    print("\n(first text after \(firstText.map { fmt($0 / .seconds(1)) } ?? "-")s, total \(fmt((ContinuousClock.now - asked) / .seconds(1)))s)")
    return 0
}

func usage() -> Int32 {
    print("usage: instant-lab run <audio> [--start s] [--duration s] [--source ja-JP] [--target zh-Hant-TW] [--trace file] [--engine apple|soniox|elevenLabs] [--ask question]")
    print("       instant-lab report <trace.jsonl>")
    return 2
}

// MARK: - Report

func report(_ path: String, truth truthPath: String? = nil) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("cannot read \(path)")
        return
    }
    let events = text.split(separator: "\n").compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
    func stage(_ name: String) -> [[String: Any]] { events.filter { $0["stage"] as? String == name } }
    func t(_ e: [String: Any]) -> Double { e["t"] as? Double ?? 0 }

    let results = stage("asr.result")
    let requests = stage("mt.request")
    let responses = stage("mt.response")
    let segs = stage("seg.update")
    let drafts = stage("mt.draft")
    let finalLines = (events.last { $0["lines"] != nil }?["lines"] as? [[String: Any]]) ?? []
    let finalSources = Set(finalLines.compactMap { $0["source"] as? String })

    // When each line's text first appeared on screen, and when its translation landed.
    var appeared: [String: Double] = [:]
    for seg in segs {
        for key in ["added", "changed"] {
            for line in seg[key] as? [[String: Any]] ?? [] {
                if let source = line["source"] as? String, appeared[source] == nil { appeared[source] = t(seg) }
            }
        }
    }
    var translated: [String: Double] = [:]
    for response in responses {
        if let source = response["source"] as? String, translated[source] == nil { translated[source] = t(response) }
    }
    let lineWait = finalSources.compactMap { source in
        appeared[source].flatMap { start in translated[source].map { $0 - start } }
    }

    let audioEnd = stage("audio.end").last?["audio"] as? Double ?? stage("audio.fed").last?["audio"] as? Double ?? 0
    let lengths = finalLines.compactMap { ($0["source"] as? String)?.count }
    let stale = responses.filter { $0["stale"] as? Bool == true }.count
    let unused = requests.filter { !finalSources.contains($0["source"] as? String ?? "") }.count

    print("""

    ── e2e report ─────────────────────────────────────────
    audio played             \(fmt(audioEnd))s
    first recognized text    \(results.first.map { fmt(t($0)) + "s" } ?? "—")
    first translated line    \(responses.first.map { fmt(t($0)) + "s" } ?? "—")
    asr results              \(results.count) (\(results.filter { $0["kind"] as? String == "final" }.count) final)
    asr lag behind audio     \(stats(results.compactMap { $0["lag"] as? Double }))
    asr update interval      \(stats(zip(results.dropFirst(), results).map { t($0) - t($1) }))
    lines                    \(finalLines.count), length \(stats(lengths.map(Double.init), unit: " chars")); \(lengths.filter { $0 <= 2 }.count) of 1–2 chars
    line → translation wait  \(stats(lineWait))
    mt requests              \(requests.count) for \(finalLines.count) lines; \(unused) for text that didn't survive, \(stale) stale on arrival
    mt time                  \(stats(responses.compactMap { ($0["ms"] as? Int).map { Double($0) / 1000 } }))
    draft translations       \(drafts.count) (\(drafts.filter { $0["stale"] as? Bool == true }.count) stale), \(stats(drafts.compactMap { ($0["ms"] as? Int).map { Double($0) / 1000 } }))
    chinese for live text    \(stats(zip(drafts.dropFirst(), drafts).map { t($0) - t($1) })) between draft updates
    shown captions rewritten \(stage("seg.rewrite").count) (revisions under locked captions: \(stage("seg.realign").filter { $0["method"] as? String == "ending" }.count) realigned by ending, \(stage("seg.realign").filter { $0["method"] as? String == "count" }.count) by count)
    main-thread stalls       \(stage("main.stall").count) over 250ms, worst \(stage("main.load").compactMap { $0["worst_ms"] as? Int }.max().map { "\($0)ms" } ?? "—")
    errors                   \(events.filter { ($0["stage"] as? String)?.hasSuffix(".error") == true }.count)
    ───────────────────────────────────────────────────────
    """)
    let assigned = Dictionary(stage("spk.assign").compactMap { e in (e["id"] as? Int).map { ($0, e) } }, uniquingKeysWith: { _, last in last })
    if !assigned.isEmpty || !stage("spk.start").isEmpty {
        let speakers = assigned.values.compactMap { $0["speaker"] as? Int }
        let counts = Dictionary(grouping: speakers.filter { $0 >= 0 }, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }
        print("""
        speakers                 \(counts.map { "\(speakerLetter($0.key))×\($0.value)" }.joined(separator: " ")), \(speakers.filter { $0 < 0 }.count) unassigned; model load \(stage("spk.start").first?["load_ms"] as? Int ?? 0)ms
        speaker wait             \(stats(assigned.values.compactMap { ($0["wait_ms"] as? Int).map { Double($0) / 1000 } })), \(assigned.values.filter { $0["covered"] as? Bool == false }.count) shown before diarization reached them
        diarization lag          \(stats(stage("spk.update").compactMap { $0["lag"] as? Double })) behind audio; \(stage("spk.start").first.map { "\($0["model"] ?? "") on \($0["units"] ?? "")" } ?? "")
        """)
        if let truthPath, let accuracy = speakerAccuracy(assigned: Array(assigned.values), truthPath: truthPath) {
            print("speaker accuracy         \(accuracy)")
        }
    }
    for line in finalLines {
        let speaker = (line["id"] as? Int).flatMap { assigned[$0]?["speaker"] as? Int }.map { "[\(speakerLetter($0))] " } ?? ""
        print("  \(speaker)\(line["translation"] as? String ?? "")")
        print("    \(line["source"] as? String ?? "")")
    }
}

func speakerLetter(_ speaker: Int) -> String {
    speaker < 0 ? "?" : String(UnicodeScalar(UInt8(65 + speaker)))
}

/// Compares assigned speakers with a ground-truth file of turns ({speaker, start, end}): each line
/// takes the truth speaker it overlaps most; predicted slots map to the truth speaker they agree
/// with most often (slot numbering is arbitrary).
func speakerAccuracy(assigned: [[String: Any]], truthPath: String) -> String? {
    guard let data = FileManager.default.contents(atPath: truthPath),
          let turns = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    var pairs: [(predicted: Int, truth: String)] = []
    for line in assigned {
        guard let start = line["start"] as? Double, let end = line["end"] as? Double,
              let predicted = line["speaker"] as? Int else { continue }
        let overlaps = turns.map { turn -> (String, Double) in
            let s = turn["start"] as? Double ?? 0, e = turn["end"] as? Double ?? 0
            return (turn["speaker"] as? String ?? "?", max(0, min(end, e) - max(start, s)))
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { continue }
        pairs.append((predicted, best.0))
    }
    guard !pairs.isEmpty else { return "no lines overlap the truth" }
    var mapping: [Int: String] = [:]
    for predicted in Set(pairs.map(\.predicted)) where predicted >= 0 {
        let truths = pairs.filter { $0.predicted == predicted }.map(\.truth)
        mapping[predicted] = Dictionary(grouping: truths, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
    let correct = pairs.filter { mapping[$0.predicted] == $0.truth }.count
    let detail = pairs.map { "\(speakerLetter($0.predicted))→\($0.truth)" }.joined(separator: " ")
    return "\(correct)/\(pairs.count) lines (\(Int(Double(correct) / Double(pairs.count) * 100))%) · \(detail)"
}

func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

func stats(_ values: [Double], unit: String = "s") -> String {
    guard !values.isEmpty else { return "—" }
    let sorted = values.sorted()
    func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
    return "median \(fmt(p(0.5)))\(unit), p90 \(fmt(p(0.9)))\(unit), max \(fmt(sorted.last!))\(unit)"
}

func reference(_ args: [String]) async -> Int32 {
    var args = args
    func option(_ name: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
        defer { args.removeSubrange(i...i + 1) }
        return args[i + 1]
    }
    let start = Double(option("--start", "0")) ?? 0
    let duration = Double(option("--duration", "0")) ?? 0
    let out = option("--out", "/tmp/instant-reference.json")
    guard let path = args.first else { return usage() }
    do {
        let samples = try AudioConverter().resampleAudioFile(path: path)
        let from = min(samples.count, Int(start * 16_000))
        let to = duration > 0 ? min(samples.count, from + Int(duration * 16_000)) : samples.count
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        let result = try await manager.process(audio: Array(samples[from..<to]))
        // Times relative to the clip start, matching a session that starts playing at `start`.
        let turns = result.segments.map { segment in
            ["speaker": segment.speakerId, "start": Double(segment.startTimeSeconds), "end": Double(segment.endTimeSeconds)] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: turns, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: out))
        let speakers = Set(turns.compactMap { $0["speaker"] as? String })
        print("\(turns.count) turns, speakers \(speakers.sorted()) → \(out)")
        return 0
    } catch {
        print("reference failed: \(error)")
        return 1
    }
}

/// Times Sortformer model loading per compute-unit choice (each loaded twice).
func loadBench() async -> Int32 {
    for (name, units) in [("all", MLComputeUnits.all), ("cpuAndGPU", .cpuAndGPU), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuOnly", .cpuOnly)] {
        for attempt in 1...2 {
            let start = ContinuousClock.now
            _ = try? await SortformerModels.loadFromHuggingFace(config: .default, computeUnits: units)
            print("\(name) #\(attempt): \(fmt(Trace.seconds(ContinuousClock.now - start)))s")
        }
    }
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run": exit(await run(Array(arguments.dropFirst())))
case "reference": exit(await reference(Array(arguments.dropFirst())))
case "loadbench": exit(await loadBench())
case "report" where arguments.count > 1: report(arguments[1], truth: arguments.count > 2 ? arguments[2] : nil); exit(0)
default: exit(usage())
}
