import InstantCore
import SwiftUI

/// Pickers for the spoken and translated languages, shown in the window's title menu.
struct LanguagePickers: View {
    @Bindable var session: LiveSession
    /// One row, "日文 → 中文", instead of a labeled picker each.
    var inline = false
    @State private var spoken: [Locale] = []
    @State private var targets: [Locale.Language] = []

    var body: some View {
        Group {
            if inline {
                HStack(spacing: 4) {
                    source
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    target
                }
                .labelsHidden()
                .fixedSize()
            } else {
                source
                target
            }
        }
        .disabled(session.status.isActive)
        .task {
            spoken = await AppleProvider.supportedLocales().sorted { Self.name($0.bcp47) < Self.name($1.bcp47) }
            targets = await AppleTranslator.supportedLanguages().sorted { Self.name($0.minimalIdentifier) < Self.name($1.minimalIdentifier) }
        }
    }

    private var source: some View {
        Picker("聽", selection: sourceID) {
            ForEach(spoken, id: \.bcp47) { locale in
                Text(inline ? Self.shortName(locale.bcp47, among: spoken.map(\.bcp47)) : Self.name(locale.bcp47)).tag(locale.bcp47)
            }
        }
    }

    private var target: some View {
        Picker("翻譯成", selection: targetID) {
            ForEach(targets, id: \.maximalIdentifier) { language in
                Text(inline ? Self.shortName(language.minimalIdentifier, among: targets.map(\.minimalIdentifier))
                            : Self.name(language.minimalIdentifier))
                    .tag(language.maximalIdentifier)
            }
        }
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

    /// "日文" rather than "日文（日本）", where space is short, unless another entry shares the
    /// language (中文（台灣）and 中文（中國）keep their regions).
    static func shortName(_ identifier: String, among all: [String]) -> String {
        func code(_ id: String) -> String { Locale(identifier: id).language.languageCode?.identifier ?? id }
        let language = code(identifier)
        guard all.filter({ code($0) == language }).count <= 1 else { return name(identifier) }
        return Locale.current.localizedString(forLanguageCode: language) ?? name(identifier)
    }
}

private extension Locale {
    var bcp47: String { identifier(.bcp47) }
}
