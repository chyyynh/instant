import Foundation
import os

/// Pipeline tracing: every stage records what it saw and when, so a bad caption can be traced
/// back to the stage that produced it (audio → asr → seg → mt).
///
/// Events go to the unified log (Console.app, subsystem `io.github.chyyynh.instant`) and, when the
/// `INSTANT_TRACE` environment variable names a file, to that file as JSON lines:
///
///     {"t":1.234,"stage":"asr.result","kind":"volatile","text":"…","lag":0.8}
///
/// `t` is seconds since the session started. `instant-lab report <file>` summarizes a trace.
public final class Trace: @unchecked Sendable {
    public static let shared = Trace()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "io.github.chyyynh.instant", category: "pipeline")
    private var handle: FileHandle?
    private var start = ContinuousClock.now

    /// Restarts the clock and (re)opens the trace file named by `INSTANT_TRACE`, if any.
    public func begin(path: String? = ProcessInfo.processInfo.environment["INSTANT_TRACE"]) {
        lock.withLock {
            try? handle?.close()
            handle = nil
            start = .now
            guard let path else { return }
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        }
    }

    public var elapsed: TimeInterval {
        lock.withLock { Self.seconds(ContinuousClock.now - start) }
    }

    public func event(_ stage: String, _ fields: [String: any Sendable] = [:]) {
        lock.withLock {
            var record = fields
            record["t"] = (Self.seconds(ContinuousClock.now - start) * 1000).rounded() / 1000
            record["stage"] = stage
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            logger.log("\(line, privacy: .public)")
            handle?.write(Data((line + "\n").utf8))
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
