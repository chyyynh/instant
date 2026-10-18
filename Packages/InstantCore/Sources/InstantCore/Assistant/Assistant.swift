import Foundation
import Observation

/// A conversation with Claude about what's being said, while it's being said.
///
/// Each question goes out with the captions added since the previous one, so the conversation is
/// append-only: earlier turns (and their thinking) are never rewritten, which keeps them valid
/// and lets the prompt cache cover everything already sent.
@MainActor
@Observable
public final class Assistant {
    public struct Message: Identifiable, Equatable, Sendable {
        public enum Role: Sendable { case user, assistant }
        public let id: Int
        public let role: Role
        public var text: String
        /// How many captions Claude had seen when this question was asked.
        public var captionCount = 0
    }

    public private(set) var messages: [Message] = []
    /// Id of the reply still streaming in.
    public private(set) var respondingTo: Message.ID?
    public var errorMessage: String?

    public var isResponding: Bool { respondingTo != nil }
    /// Whether the last answer can be asked again.
    public var canRetry: Bool { beforeLast != nil && !isResponding }

    @ObservationIgnored private var history: [JSONValue] = []
    /// Captions already sent; the next question carries the ones after these.
    @ObservationIgnored private var sentCaptions = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The conversation before the last exchange, to ask it again from there.
    private var beforeLast: (history: [JSONValue], sentCaptions: Int)?

    public static let system = """
    使用者正在聽一段外語的對話（會議、課程、影片或面對面交談），一邊和你討論。\
    每則訊息開頭的 <transcript> 是從上一則訊息之後新增的逐字稿：時間、說話者、原文與機器翻譯。\
    逐字稿是即時語音辨識加上機器翻譯，可能有聽錯、斷句錯誤或翻譯不準的地方；說話者是用聲音自動區分的，也可能標錯。\
    需要時根據原文判斷，並在重要的地方指出可能的誤聽或誤譯。標示「還在說」的內容尚未定稿，之後的逐字稿可能會重複出現。

    用繁體中文回答。使用者正在聽對話，只能瞄一眼：先給結論，預設最多三到五個短重點，不要分段標題；使用者要求詳細時再展開。
    """

    public init() {}

    /// Asks `question` about the session so far. `speakerName` names a diarized speaker slot.
    public func ask(_ question: String, captions: [Line], pending: String,
                    speakerName: (Int) -> String, client: ClaudeClient) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        // The captions were cleared since: what Claude saw is gone, so start over.
        if captions.count < sentCaptions { reset() }
        errorMessage = nil

        let fresh = captions[sentCaptions...]
        let turn = Self.turn(question: question, captions: fresh, pending: pending, speakerName: speakerName)
        let userMessage = Message(id: messages.count, role: .user, text: question, captionCount: captions.count)
        let reply = Message(id: messages.count + 1, role: .assistant, text: "")
        messages += [userMessage, reply]
        respondingTo = reply.id
        let request = history + [["role": "user", "content": .string(turn)]]
        let captionCount = captions.count

        task = Task {
            defer { respondingTo = nil }
            do {
                let message = try await client.stream(system: Self.system, messages: request) { [weak self] text in
                    guard let self, let index = messages.firstIndex(where: { $0.id == reply.id }) else { return }
                    messages[index].text += text
                }
                try Task.checkCancellation()
                guard message.stopReason != "refusal" else {
                    discard(userMessage, reply, error: "Claude 這次拒絕回答，換個問法試試。")
                    return
                }
                beforeLast = (history, sentCaptions)
                history = request + [["role": "assistant", "content": .array(message.historyContent)]]
                sentCaptions = captionCount
            } catch is CancellationError {
                discard(userMessage, reply, error: nil)
            } catch let error as URLError where error.code == .cancelled {
                discard(userMessage, reply, error: nil)
            } catch {
                discard(userMessage, reply, error: error.localizedDescription)
            }
        }
    }

    /// Asks the last question again, with the captions as they are now. Only the last exchange
    /// can be redone: taking it out leaves the conversation before it untouched.
    public func retryLast(captions: [Line], pending: String, speakerName: (Int) -> String, client: ClaudeClient) {
        guard canRetry, let before = beforeLast, messages.count >= 2, messages[messages.count - 2].role == .user else { return }
        let question = messages[messages.count - 2].text
        messages.removeLast(2)
        history = before.history
        sentCaptions = before.sentCaptions
        beforeLast = nil
        ask(question, captions: captions, pending: pending, speakerName: speakerName, client: client)
    }

    /// Stops the reply in progress; the question is dropped, so the conversation stays as it was.
    public func cancel() {
        task?.cancel()
    }

    public func reset() {
        task?.cancel()
        task = nil
        messages = []
        history = []
        sentCaptions = 0
        beforeLast = nil
        respondingTo = nil
        errorMessage = nil
    }

    #if DEBUG
    /// Debug-only: a canned conversation, for checking the UI without calling the API.
    public func showDemo(_ exchanges: [(question: String, answer: String, captions: Int)]) {
        reset()
        for exchange in exchanges {
            messages.append(Message(id: messages.count, role: .user, text: exchange.question, captionCount: exchange.captions))
            messages.append(Message(id: messages.count, role: .assistant, text: exchange.answer))
        }
    }
    #endif

    /// Takes a failed exchange back out. The history wasn't extended, so the captions it carried
    /// go out again with the next question.
    private func discard(_ question: Message, _ reply: Message, error: String?) {
        messages.removeAll { $0.id == question.id || $0.id == reply.id }
        errorMessage = error
    }

    /// One user turn: the new transcript, then the question.
    static func turn(question: String, captions: ArraySlice<Line>, pending: String, speakerName: (Int) -> String) -> String {
        var lines: [String] = []
        var previous: Int?
        for line in captions {
            let time = Duration.seconds(line.start.rounded(.down)).formatted(.time(pattern: .minuteSecond))
            let speaker = line.speaker.map(speakerName) ?? "?"
            // The speaker only when it changes, like a script.
            let header = line.speaker != nil && line.speaker == previous ? "" : "\(speaker)："
            previous = line.speaker
            lines.append("[\(time)] \(header)\(line.source)")
            if let translation = line.translation, !translation.isEmpty { lines.append("　譯：\(translation)") }
        }
        let pending = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { lines.append("（還在說）\(pending)") }
        let transcript = lines.isEmpty ? "（沒有新的內容）" : lines.joined(separator: "\n")
        return "<transcript>\n\(transcript)\n</transcript>\n\n\(question)"
    }
}
