import Foundation
import InstantCore

// End-to-end runs of the live pipeline on real audio, played at real-time speed.
//
//   instant-lab run <audio> [--start s] [--duration s] [--source ja-JP] [--target zh-Hant-TW] [--trace file]
//   instant-lab report <trace.jsonl>
//
// `run` writes a trace (default /tmp/instant-trace.jsonl) and prints the report.
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
    guard let path = args.first else { return usage() }

    setenv("INSTANT_TRACE", tracePath, 1)
    let session = LiveSession(sourceLocale: Locale(identifier: source), targetLanguage: Locale.Language(identifier: target))
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
    report(tracePath)
    if case .failed = session.status { return 1 }
    return 0
}

func usage() -> Int32 {
    print("usage: instant-lab run <audio> [--start s] [--duration s] [--source ja-JP] [--target zh-Hant-TW] [--trace file]")
    print("       instant-lab report <trace.jsonl>")
    return 2
}

// MARK: - Report

func report(_ path: String) {
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
    lines                    \(finalLines.count), length \(stats(lengths.map(Double.init), unit: " chars"))
    line → translation wait  \(stats(lineWait))
    mt requests              \(requests.count) for \(finalLines.count) lines; \(unused) for text that didn't survive, \(stale) stale on arrival
    mt time                  \(stats(responses.compactMap { ($0["ms"] as? Int).map { Double($0) / 1000 } }))
    draft translations       \(drafts.count) (\(drafts.filter { $0["stale"] as? Bool == true }.count) stale), \(stats(drafts.compactMap { ($0["ms"] as? Int).map { Double($0) / 1000 } }))
    chinese for live text    \(stats(zip(drafts.dropFirst(), drafts).map { t($0) - t($1) })) between draft updates
    main-thread stalls       \(stage("main.stall").count) over 250ms, worst \(stage("main.load").compactMap { $0["worst_ms"] as? Int }.max().map { "\($0)ms" } ?? "—")
    errors                   \(events.filter { ($0["stage"] as? String)?.hasSuffix(".error") == true }.count)
    ───────────────────────────────────────────────────────
    """)
    for line in finalLines {
        print("  \(line["translation"] as? String ?? "")")
        print("    \(line["source"] as? String ?? "")")
    }
}

func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

func stats(_ values: [Double], unit: String = "s") -> String {
    guard !values.isEmpty else { return "—" }
    let sorted = values.sorted()
    func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
    return "median \(fmt(p(0.5)))\(unit), p90 \(fmt(p(0.9)))\(unit), max \(fmt(sorted.last!))\(unit)"
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run": exit(await run(Array(arguments.dropFirst())))
case "report" where arguments.count > 1: report(arguments[1]); exit(0)
default: exit(usage())
}
