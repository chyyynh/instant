import SwiftUI

@main
struct InstantApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 560, height: 760)
        #endif
    }
}
