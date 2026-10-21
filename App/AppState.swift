import InstantCore
import SwiftUI

/// Window-level UI state shared by the main window, the floating captions, the menu bar and the
/// menu commands (the session itself is shared separately).
@MainActor
@Observable
final class AppUI {
    /// Mac: the Claude inspector.
    var inspectorShown = false
    /// Mac: the speaker list, a popover from the toolbar.
    var speakersShown = false
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

    /// Speaker slot being renamed; drives the rename alert.
    var renamingSpeaker: Int?
    var newSpeakerName = ""

    func setAPIKey(_ key: String?) {
        APIKey.anthropic.save(key)
        apiKey = APIKey.anthropic.load()
    }

    func setSpeechKey(_ key: String?, for engine: SpeechEngine) {
        APIKey.speech(engine).save(key)
        speechKeySet[engine] = APIKey.speech(engine).load() != nil
    }

    func rename(_ speaker: Int, in session: LiveSession) {
        newSpeakerName = session.speakerNames[speaker] ?? ""
        renamingSpeaker = speaker
    }
}

/// Preference keys, shared by @AppStorage users.
enum Pref {
    static let captionPoints = "captionPoints"
    static let showOriginal = "showOriginal"
    static let overlayLines = "overlayLines"
    static let overlayTranslationOnly = "overlayTranslationOnly"
    static let speakersEnabled = "speakersEnabled"
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

/// One person in the speaker list: slots given the same name are merged into one.
struct Speaker: Identifiable, Equatable {
    /// Lowest slot with this name; it decides the color.
    let id: Int
    let slots: Set<Int>
    let name: String
    let color: Color
}

extension LiveSession {
    static let speakerColors: [Color] = [.blue, .orange, .green, .purple]

    /// "田中", or "說話者 A" for an unnamed slot.
    func displayName(of speaker: Int) -> String {
        speakerNames[speaker].flatMap { $0.isEmpty ? nil : $0 }
            ?? "說話者 \(String(UnicodeScalar(UInt8(65 + (speakerOrder.firstIndex(of: speaker) ?? speaker)))))"
    }

    /// Slots given the same name share the color of the lowest such slot, so they read as one person.
    func speakerColor(_ speaker: Int) -> Color {
        Self.speakerColors[speakerColorIndex(speaker)]
    }

    /// Index into `speakerColors`, for keeping a speaker's color in a saved listening.
    func speakerColorIndex(_ speaker: Int) -> Int {
        let slot = speakerNames[speaker].flatMap { given in
            speakerNames.filter { $0.value == given }.keys.min()
        } ?? speaker
        let index = speakerOrder.firstIndex(of: slot) ?? slot
        return index % Self.speakerColors.count
    }

    /// People heard so far, in order of first appearance, with same-named slots merged.
    var speakers: [Speaker] {
        var result: [Speaker] = []
        for slot in speakerOrder {
            let name = displayName(of: slot)
            if let index = result.firstIndex(where: { $0.name == name }) {
                let merged = result[index]
                result[index] = Speaker(id: min(merged.id, slot), slots: merged.slots.union([slot]), name: name, color: merged.color)
            } else {
                result.append(Speaker(id: slot, slots: [slot], name: name, color: speakerColor(slot)))
            }
        }
        return result
    }

    /// Captions per speaker slot.
    var lineCounts: [Int: Int] {
        captions.reduce(into: [:]) { counts, line in
            if let speaker = line.speaker { counts[speaker, default: 0] += 1 }
        }
    }

    /// The transcript as plain text, with speaker names, for sharing and copying.
    var transcriptText: String {
        var previous: Int?
        return captions.map { line in
            defer { previous = line.speaker }
            let header = line.speaker.flatMap { $0 == previous ? nil : "\(displayName(of: $0))：\n" } ?? ""
            return "\(header)\(line.translation ?? "")\n\(line.source)"
        }.joined(separator: "\n\n")
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

/// A speaker's name with their color as a dot; the text stays secondary so orange or green names
/// remain readable on a light background.
struct SpeakerLabel: View {
    let name: String
    let color: Color

    var body: some View {
        Label {
            Text(name)
        } icon: {
            Image(systemName: "circle.fill")
                .foregroundStyle(color)
                .imageScale(.small)
        }
        .foregroundStyle(.secondary)
    }
}

/// Renaming a speaker: shared by the caption context menu, the inspector and the iOS chips.
struct RenameSpeakerAlert: ViewModifier {
    @Environment(LiveSession.self) private var session
    @Environment(AppUI.self) private var ui

    func body(content: Content) -> some View {
        @Bindable var ui = ui
        content.alert("重新命名說話者", isPresented: Binding(get: { ui.renamingSpeaker != nil },
                                                          set: { if !$0 { ui.renamingSpeaker = nil } })) {
            TextField("名字，例如：田中", text: $ui.newSpeakerName)
            Button("取消", role: .cancel) {}
            Button("確定") {
                if let speaker = ui.renamingSpeaker {
                    let name = ui.newSpeakerName.trimmingCharacters(in: .whitespaces)
                    session.speakerNames[speaker] = name.isEmpty ? nil : name
                }
            }
        } message: {
            Text("取同一個名字的說話者會合併顯示。")
        }
    }
}

extension View {
    func renameSpeakerAlert() -> some View { modifier(RenameSpeakerAlert()) }
}
