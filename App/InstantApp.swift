import InstantCore
import SwiftUI

@main
struct InstantApp: App {
    /// One session for every window: the main window, the floating captions, the menu bar.
    @State private var session: LiveSession
    @State private var ui: AppUI
    @State private var assistant = Assistant()
    #if os(macOS)
    @AppStorage(Pref.showMenuBarExtra) private var showMenuBarExtra = true
    #endif

    init() {
        let session = LiveSession()
        session.speakerDiarizationEnabled = UserDefaults.standard.object(forKey: Pref.speakersEnabled) as? Bool ?? true
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
        }
        #endif
    }
}
