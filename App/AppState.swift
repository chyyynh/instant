import InstantCore
import SwiftUI

/// Window-level UI state shared by the main window, the floating captions, the menu bar and the
/// menu commands (the session itself is shared separately).
@MainActor
@Observable
final class AppUI {
    /// Mac: the Claude inspector.
    var inspectorShown = false
    /// iOS: the AI sheet.
    var assistantShown = false
    /// Whether the question field has focus (Space is typed there, not start / stop).
    var composerFocused = false
    /// Caption to scroll to and highlight, asked for from the Claude panel.
    var revealedCaption: Int?
    private(set) var apiKey = APIKey.anthropic.load()
    /// Which cloud recognizers have a key, for Settings.
    private(set) var speechKeySet = Dictionary(uniqueKeysWithValues: SpeechEngine.allCases.map { ($0, APIKey.speech($0).load() != nil) })
    /// Whether the floating captions are showing.
    var overlayShown = false {
        didSet {
            #if os(macOS)
            guard overlayShown != oldValue, let session else { return }
            overlayShown ? overlayPanel.show(session: session, ui: self) : overlayPanel.hide()
            #endif
        }
    }
    #if os(macOS)
    @ObservationIgnored weak var session: LiveSession?
    @ObservationIgnored private let overlayPanel = OverlayPanel()
    #endif
    /// Playback of the last listening's recording, once it has stopped.
    var player: Player?
    /// The last listening, once saved to the library.
    var savedListening: SavedListening.ID?
    /// The save sheet for the last listening.
    var savingShown = false
    /// Waiting on the user: starting over (or clearing) would lose an unsaved recording.
    var unsavedAction: UnsavedAction?
    /// Done after the save sheet saves (the action that asked to save first).
    var afterSave: UnsavedAction?
    #if os(iOS)
    var libraryShown = false
    #endif

    enum UnsavedAction { case start, clear }

    /// A recording with captions that isn't in the library yet.
    func hasUnsavedRecording(_ session: LiveSession) -> Bool {
        session.recording != nil && savedListening == nil && !session.captions.isEmpty
    }

    /// Starts listening, asking first if that would drop an unsaved recording.
    func start(_ session: LiveSession) {
        if hasUnsavedRecording(session) { unsavedAction = .start } else { perform(.start, session) }
    }

    /// Clears the captions, asking first if that would drop an unsaved recording.
    func clear(_ session: LiveSession) {
        if hasUnsavedRecording(session) { unsavedAction = .clear } else { perform(.clear, session) }
    }

    func perform(_ action: UnsavedAction, _ session: LiveSession) {
        player?.stop()
        switch action {
        case .start: Task { await session.start() }
        case .clear: session.clear()
        }
    }

    func setAPIKey(_ key: String?) {
        APIKey.anthropic.save(key)
        apiKey = APIKey.anthropic.load()
    }

    func setSpeechKey(_ key: String?, for engine: SpeechEngine) {
        APIKey.speech(engine).save(key)
        speechKeySet[engine] = APIKey.speech(engine).load() != nil
    }
}

/// Preference keys, shared by @AppStorage users.
enum Pref {
    static let captionPoints = "captionPoints"
    static let showOriginal = "showOriginal"
    static let overlayLines = "overlayLines"
    static let overlayTranslationOnly = "overlayTranslationOnly"
    static let speechEngine = "speechEngine"
    static let recordingEnabled = "recordingEnabled"
    static let showMenuBarExtra = "showMenuBarExtra"
}

/// Caption size in points, set by the slider in Settings and ⌘+ / ⌘− / ⌘0. On iOS the views also
/// scale it with Dynamic Type; macOS has no Dynamic Type, so there it's the size on screen.
enum CaptionMetrics {
    static let range: ClosedRange<Double> = 15...36
    static let standard: Double = 21
    static let step: Double = 2

    static func translationFont(_ points: Double) -> Font { .system(size: points, weight: .semibold) }
    static func originalFont(_ points: Double) -> Font { .system(size: (points * 0.67).rounded()) }
}

extension LiveSession {
    /// The transcript as plain text, for sharing and copying.
    var transcriptText: String {
        captions.map { "\($0.translation ?? "")\n\($0.source)" }.joined(separator: "\n\n")
    }

    /// Short language names for titles: the spoken language in its own name ("日本語"), the
    /// target in the reader's ("中文").
    var languageTitle: String {
        let source = sourceLocale.language.languageCode?.identifier ?? sourceLocale.identifier
        let target = targetLanguage.languageCode?.identifier ?? targetLanguage.minimalIdentifier
        let sourceName = Locale(identifier: source).localizedString(forLanguageCode: source) ?? source
        let targetName = Locale.current.localizedString(forLanguageCode: target) ?? target
        return "\(sourceName) → \(targetName)"
    }

    var inputName: String { input == .microphone ? "麥克風" : "Mac 聲音" }
    var inputSymbol: String { input == .microphone ? "mic" : "speaker.wave.2" }
}
