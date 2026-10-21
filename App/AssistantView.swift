import InstantCore
import Security
import SwiftUI

/// The Anthropic API key, kept in the keychain. `ANTHROPIC_API_KEY` in the environment stands in
/// for it in development.
struct APIKey {
    let account: String
    /// Used when the keychain has no key, e.g. in development.
    let environment: String

    static let anthropic = APIKey(account: "anthropic-api-key", environment: "ANTHROPIC_API_KEY")

    static func speech(_ engine: SpeechEngine) -> APIKey {
        switch engine {
        case .soniox: APIKey(account: "soniox-api-key", environment: "SONIOX_API_KEY")
        case .elevenLabs: APIKey(account: "elevenlabs-api-key", environment: "ELEVENLABS_API_KEY")
        case .apple: APIKey(account: "", environment: "")
        }
    }

    private var query: [String: Any] {[
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.chyyynh.instant",
        kSecAttrAccount as String: account,
    ]}

    func load() -> String? {
        guard !account.isEmpty else { return nil }
        var query = query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return ProcessInfo.processInfo.environment[environment].flatMap { $0.isEmpty ? nil : $0 }
    }

    func save(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

extension Assistant {
    /// Asks about everything captioned so far, with speakers by the names shown on screen.
    func ask(_ question: String, session: LiveSession, ui: AppUI) {
        guard let apiKey = ui.apiKey else { return }
        ask(question, captions: session.captions, pending: session.pendingText,
            speakerName: { session.displayName(of: $0) }, client: ClaudeClient(apiKey: apiKey))
    }

    func retryLast(session: LiveSession, ui: AppUI) {
        guard let apiKey = ui.apiKey else { return }
        retryLast(captions: session.captions, pending: session.pendingText,
                  speakerName: { session.displayName(of: $0) }, client: ClaudeClient(apiKey: apiKey))
    }
}

/// Talking with Claude about what's being said: the Mac inspector, the iOS sheet.
struct AssistantView: View {
    @Environment(LiveSession.self) private var session
    @Environment(Assistant.self) private var assistant
    @Environment(AppUI.self) private var ui
    @State private var question = ""
    @FocusState private var composerFocused: Bool

    /// One tap while listening: typing is slow when you're also following the conversation. The
    /// first few in a row, short enough for the narrowest panel; the rest behind "⋯".
    static let suggestions: [(label: String, question: String)] = [
        ("在講什麼？", "剛剛在講什麼？"),
        ("有聽錯嗎？", "有聽錯或翻錯的嗎？"),
        ("怎麼回應？", "我可以怎麼回應？"),
    ]
    static let moreSuggestions = ["整理目前的重點", "說詳細一點", "有哪些待辦或決定？", "有什麼我可能沒聽懂的文化背景？"]

    var body: some View {
        if ui.apiKey == nil {
            APIKeyPrompt()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if assistant.messages.isEmpty { intro }
                    ForEach(assistant.messages) { message in
                        MessageRow(message: message, streaming: assistant.respondingTo == message.id,
                                   isLast: message.id == assistant.messages.last?.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaBar(edge: .bottom) { composer }
            .onChange(of: composerFocused) { ui.composerFocused = composerFocused }
            .onAppear { composerFocused = true }
        }
    }

    private var intro: some View {
        Text("邊聽邊問 Claude：每次提問都會帶上到目前為止的逐字稿。可以點下面的快速提問，或自己打字。")
            .foregroundStyle(.secondary)
    }

    private var quickQuestions: some View {
        // Plain bordered buttons: glass is for controls floating over content, and these sit in it.
        HStack(spacing: 6) {
            ForEach(Self.suggestions, id: \.question) { suggestion in
                Button { send(suggestion.question) } label: {
                    Text(suggestion.label)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .help(suggestion.question)
            }
            Menu {
                ForEach(Self.moreSuggestions, id: \.self) { question in
                    Button(question) { send(question) }
                }
            } label: {
                Label("更多提問", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(assistant.isResponding || session.captions.isEmpty && session.pendingText.isEmpty)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = assistant.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            quickQuestions
            HStack(spacing: 8) {
                TextField("問 Claude 關於這段對話…", text: $question)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { send(question) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.fill.tertiary, in: .capsule)
                if assistant.isResponding {
                    Button("停止", systemImage: "stop.fill") { assistant.cancel() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                } else {
                    Button("送出", systemImage: "arrow.up") { send(question) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func send(_ text: String) {
        guard !assistant.isResponding, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        assistant.ask(text, session: session, ui: ui)
        question = ""
    }
}

private struct MessageRow: View {
    @Environment(LiveSession.self) private var session
    @Environment(Assistant.self) private var assistant
    @Environment(AppUI.self) private var ui
    let message: Assistant.Message
    let streaming: Bool
    let isLast: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 16))
                scope
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 32)
        case .assistant:
            if message.text.isEmpty, streaming {
                Label("思考中…", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            } else {
                Text(Self.markdown(message.text))
                    #if os(macOS)
                    .font(.title3) // a glance away from 21pt captions; 13pt body is too small to skim
                    #endif
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .contextMenu {
                        Button("拷貝回答", systemImage: "doc.on.doc") { copy(message.text) }
                        if isLast {
                            Button("重新回答", systemImage: "arrow.clockwise") { assistant.retryLast(session: session, ui: ui) }
                                .disabled(!assistant.canRetry)
                        }
                    }
            }
        }
    }

    /// Where in the captions the question was asked: "到 02:09 · 田中 ›", tapping shows that caption.
    @ViewBuilder
    private var scope: some View {
        let index = message.captionCount - 1
        if session.captions.indices.contains(index) {
            let line = session.captions[index]
            let time = Duration.seconds(line.start.rounded(.down)).formatted(.time(pattern: .minuteSecond))
            let speaker = line.speaker.map { " · \(session.displayName(of: $0))" } ?? ""
            Button("到 \(time)\(speaker) ›") { ui.revealedCaption = index }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tint)
                .help("在字幕中顯示這句")
        } else {
            Text("還沒有字幕")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Bold, italics, code and links, with "- " list items as bullets; line breaks kept as written.
    static func markdown(_ text: String) -> AttributedString {
        let text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? "• " + $0.dropFirst(2) : $0 }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Before a key is set: what it's for, where to get one, and a field to paste it.
private struct APIKeyPrompt: View {
    @Environment(AppUI.self) private var ui
    @State private var key = ""

    var body: some View {
        ContentUnavailableView {
            Label("和 Claude 討論", systemImage: "sparkles")
        } description: {
            Text("輸入 Anthropic API key，就能邊聽邊問 Claude。提問時會把逐字稿傳給 Anthropic，聲音不會上傳。")
        } actions: {
            VStack(spacing: 12) {
                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(save)
                Button("儲存", action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Link("取得 API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                    .font(.callout)
            }
        }
    }

    private func save() {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        ui.setAPIKey(key)
    }
}

/// The key in Settings: replace or remove it.
struct AssistantSettings: View {
    @Environment(AppUI.self) private var ui
    @State private var key = ""

    var body: some View {
        Section {
            if ui.apiKey != nil {
                LabeledContent("API key", value: "已設定")
                Button("移除 API key", role: .destructive) { ui.setAPIKey(nil) }
            } else {
                SecureField("API key", text: $key, prompt: Text("sk-ant-…"))
                    .onSubmit { ui.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                Link("取得 API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("提問時，到目前為止的逐字稿（原文與翻譯）會傳送到 Anthropic；聲音不會上傳。API key 存在這台裝置的鑰匙圈裡。")
        }
    }
}

#if os(iOS)
/// iOS: the conversation in a sheet that leaves the captions visible at medium height.
struct AssistantSheet: View {
    @Environment(Assistant.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AssistantView()
                .navigationTitle("和 Claude 討論")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("新對話", systemImage: "square.and.pencil") { assistant.reset() }
                            .disabled(assistant.messages.isEmpty)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
#endif
