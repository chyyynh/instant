import Foundation

/// Any JSON value. Request bodies are built from it and response content blocks are kept in it,
/// so blocks the app doesn't understand (thinking, fallback markers) go back to the API unchanged.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integers stay integers: max_tokens must not go out as 64000.0.
            if value == value.rounded(), abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let object) = self { object[key] } else { nil } }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}

/// Rebuilds a streamed message from its server-sent events.
///
/// Pure state so the event handling can be checked without the network.
public struct MessageAccumulator: Sendable {
    /// Content blocks in order, with their deltas applied.
    public private(set) var content: [JSONValue] = []
    public private(set) var stopReason: String?
    public private(set) var usage: JSONValue?

    public init() {}

    /// Text of the reply so far: every text block, including any partial written before a
    /// server-side fallback took over (the fallback model continues from it).
    public var text: String {
        content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
    }

    /// Applies one event; returns text added to the reply, if any.
    @discardableResult
    public mutating func apply(_ event: JSONValue) throws -> String? {
        switch event["type"]?.string {
        case "message_start":
            usage = event["message"]?["usage"]
        case "content_block_start":
            guard let index = event["index"]?.int, let block = event["content_block"] else { return nil }
            while content.count <= index { content.append(.null) }
            content[index] = block
            return block["type"]?.string == "text" ? block["text"]?.string.flatMap { $0.isEmpty ? nil : $0 } : nil
        case "content_block_delta":
            guard let index = event["index"]?.int, content.indices.contains(index), let delta = event["delta"] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                let text = delta["text"]?.string ?? ""
                content[index]["text"] = .string((content[index]["text"]?.string ?? "") + text)
                return text
            case "thinking_delta":
                content[index]["thinking"] = .string((content[index]["thinking"]?.string ?? "") + (delta["thinking"]?.string ?? ""))
            case "signature_delta":
                content[index]["signature"] = delta["signature"]
            default:
                break
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let usage = event["usage"] { self.usage = usage }
        case "error":
            throw ClaudeError.api(event["error"]?["message"]?.string ?? "未知的錯誤")
        default:
            break
        }
        return nil
    }

    /// The reply as it goes back into the conversation. After a server-side fallback, blocks
    /// other than text from before the last fallback marker belong to the model that declined,
    /// so they're left out.
    public var historyContent: [JSONValue] {
        let blocks = content.filter { $0 != .null }
        guard let boundary = blocks.lastIndex(where: { $0["type"]?.string == "fallback" }) else { return blocks }
        return blocks[..<boundary].filter { $0["type"]?.string == "text" } + blocks[(boundary + 1)...]
    }
}

public enum ClaudeError: LocalizedError {
    case http(Int, String)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .http(401, _): "API key 無效，請到設定重新輸入。"
        case .http(429, _): "請求太頻繁，稍後再試。"
        case .http(529, _): "Claude 目前太忙，稍後再試。"
        case .http(let status, let message): "Claude API 錯誤 \(status)：\(message)"
        case .api(let message): "Claude API 錯誤：\(message)"
        }
    }
}

/// Minimal streaming client for the Messages API (there's no official Swift SDK).
public struct ClaudeClient: Sendable {
    public var apiKey: String
    public var model = "claude-opus-5-5"
    /// Chat about a transcript doesn't need deep reasoning, and a quick first word matters more.
    public var effort = "low"

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Streams a reply: yields each piece of text as it arrives and returns the whole message.
    public func stream(system: String, messages: [JSONValue],
                       onText: @escaping @MainActor (String) -> Void) async throws -> MessageAccumulator {
        let body: JSONValue = [
            "model": .string(model),
            "max_tokens": 64000,
            "stream": true,
            "system": .string(system),
            "messages": .array(messages),
            "output_config": ["effort": .string(effort)],
            // Caches the conversation so far; each question only pays for what's new.
            "cache_control": ["type": "ephemeral"],
            // A declined request is retried server-side on the recommended fallback model.
            "fallbacks": "default",
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // byte-stable prefix for the prompt cache
        request.httpBody = try encoder.encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let error = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw ClaudeError.http(status, error?["error"]?["message"]?.string ?? String(decoding: data, as: UTF8.self))
        }

        var message = MessageAccumulator()
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let event = try decoder.decode(JSONValue.self, from: Data(line.dropFirst(5).utf8))
            if let text = try message.apply(event) { await onText(text) }
        }
        return message
    }
}
