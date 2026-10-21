import InstantCore
import SwiftUI

@main
struct InstantApp: App {
    /// One session for every window: the main window, the floating captions, the menu bar.
    @State private var session: LiveSession
    @State private var ui: AppUI
    @State private var assistant = Assistant()
    @State private var library = Library()
    #if os(macOS)
    @AppStorage(Pref.showMenuBarExtra) private var showMenuBarExtra = true
    #endif

    init() {
        let session = LiveSession()
        session.engine = UserDefaults.standard.string(forKey: Pref.speechEngine).flatMap(SpeechEngine.init) ?? .apple
        session.apiKey = { APIKey.speech($0).load() }
        session.recordingEnabled = UserDefaults.standard.object(forKey: Pref.recordingEnabled) as? Bool ?? true
        _session = State(initialValue: session)
        let ui = AppUI()
        #if os(macOS)
        ui.session = session
        #endif
        _ui = State(initialValue: ui)
    }

    var body: some Scene {
        #if os(macOS)
        Window("Instant", id: WindowID.main) {
            ContentView()
                .environment(session)
                .environment(ui)
                .environment(assistant)
                .environment(library)
        }
        .defaultSize(width: 560, height: 720)
        .defaultLaunchBehavior(.presented)
        .commands { InstantCommands(session: session, ui: ui, assistant: assistant) }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(session)
                .environment(ui)
        } label: {
            MenuBarLabel()
                .environment(session)
        }
        .menuBarExtraStyle(.window)

        Window("聆聽紀錄", id: WindowID.library) {
            LibraryView()
                .environment(library)
        }
        .defaultSize(width: 900, height: 640)
        // Only when asked for: never at launch, and not reopened because it was open last time.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(session)
                .environment(ui)
        }
        #else
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(ui)
                .environment(assistant)
                .environment(library)
        }
        #endif
    }
}
