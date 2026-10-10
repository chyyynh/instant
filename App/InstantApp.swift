import SwiftUI

@main
struct InstantApp: App {
    @AppStorage("captionSize") private var captionSize: CaptionSize = .medium

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 560, height: 760)
        .commands {
            // The Mac's standard text-size commands, in the View menu.
            CommandGroup(after: .toolbar) {
                Button("放大字幕") { captionSize = captionSize.larger ?? captionSize }
                    .keyboardShortcut("+")
                    .disabled(captionSize.larger == nil)
                Button("縮小字幕") { captionSize = captionSize.smaller ?? captionSize }
                    .keyboardShortcut("-")
                    .disabled(captionSize.smaller == nil)
                Divider()
            }
        }
        #endif
    }
}
