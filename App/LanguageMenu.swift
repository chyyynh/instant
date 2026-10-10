import InstantCore
import SwiftUI

/// Pickers for the spoken and translated languages, shown in the window's title menu.
struct LanguagePickers: View {
    @Bindable var session: LiveSession
    @State private var spoken: [Locale] = []
    @State private var targets: [Locale.Language] = []

    var body: some View {
        Group {
            Picker("聽", selection: sourceID) {
                ForEach(spoken, id: \.bcp47) { locale in
                    Text(Self.name(locale.bcp47)).tag(locale.bcp47)
                }
            }
            Picker("翻譯成", selection: targetID) {
                ForEach(targets, id: \.maximalIdentifier) { language in
                    Text(Self.name(language.minimalIdentifier)).tag(language.maximalIdentifier)
                }
            }
        }
        .disabled(session.status.isActive)
        .task {
            spoken = await LiveTranscriber.supportedLocales().sorted { Self.name($0.bcp47) < Self.name($1.bcp47) }
            targets = await AppleTranslator.supportedLanguages().sorted { Self.name($0.minimalIdentifier) < Self.name($1.minimalIdentifier) }
        }
    }

    /// e.g. "日文（日本）→ 中文（台灣）"
    static func title(for session: LiveSession) -> String {
        "\(name(session.sourceLocale.bcp47)) → \(name(session.targetLanguage.minimalIdentifier))"
    }

    private var sourceID: Binding<String> {
        Binding(get: { session.sourceLocale.bcp47 },
                set: { session.sourceLocale = Locale(identifier: $0) })
    }

    private var targetID: Binding<String> {
        Binding(get: { session.targetLanguage.maximalIdentifier },
                set: { session.targetLanguage = Locale.Language(identifier: $0) })
    }

    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private extension Locale {
    var bcp47: String { identifier(.bcp47) }
}
