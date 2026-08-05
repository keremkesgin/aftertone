import AppKit
import SwiftUI

/// Owns the desktop-level window, the status item, and the app's lifecycle.
///
/// Deliberately not a SwiftUI `App`/`Scene`: SwiftUI's `Window` scene has no way to set a
/// custom `NSWindow.level`, and a custom level is the entire mechanism this app depends on
/// (see `DesktopWindow`'s doc comment — spec §9's floating-`NSPanel` design was replaced
/// with a true desktop-level window per an explicit, twice-confirmed product decision).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = NowPlayingMonitor()
    private let placeholderLibrary = PlaceholderLibrary()
    private lazy var artwork = ArtworkLoader(library: placeholderLibrary)
    private let lyricsStore = LyricsStore()
    private lazy var lyrics = LyricsLibrary(store: lyricsStore)

    private var desktopWindow: DesktopWindow?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with `LSUIElement` in Info.plist: no Dock icon, no Cmd-Tab
        // entry, regardless of which one macOS happens to honor in a given release.
        NSApplication.shared.setActivationPolicy(.accessory)

        // The window spans the whole screen — this *is* the desktop overlay, not a
        // widget floating in a corner of it. `NSHostingView` will otherwise shrink an
        // `NSWindow` to its content's fitting size the moment it's assigned as
        // `contentView` (confirmed: this is exactly what put the previous version in the
        // top-left corner at 320×420 instead of the requested 620×420), so the SwiftUI
        // content itself is also told to fill this same frame explicitly, rather than
        // relying on the window's size alone.
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let window = DesktopWindow(contentRect: screenFrame)
        let content = DesktopContentView(monitor: monitor, artwork: artwork, lyrics: lyrics)
            .frame(width: screenFrame.width, height: screenFrame.height)
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(screenFrame, display: true)
        window.orderFrontRegardless()
        desktopWindow = window

        statusItemController = StatusItemController(monitor: monitor, desktopWindow: window)

        monitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The desktop window ignores mouse events and is never meant to be "closed" by
        // the user in the way a normal window is — losing it should not quit the app.
        false
    }
}
