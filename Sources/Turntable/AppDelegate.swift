import AppKit
import Combine
import SwiftUI

/// Owns the app's lifecycle: polls Spotify, resolves artwork and lyrics, and renders them
/// in a click-through window at desktop level. The user's actual wallpaper is never
/// touched — `WallpaperSetter` is unused here, kept on disk in case wallpaper mode is
/// ever brought back as an option.
///
/// Deliberately not a SwiftUI `App`/`Scene`: SwiftUI's `Window` scene has no way to set a
/// custom `NSWindow.level`, and a custom level is the entire mechanism this app depends on
/// (see `DesktopWindow`'s doc comment).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = NowPlayingMonitor()
    private lazy var artwork = ArtworkLoader(library: PlaceholderLibrary())
    private let lyricsStore = LyricsStore()
    private lazy var lyrics = LyricsLibrary(store: lyricsStore)
    private let lyricsSyncSettings = LyricsSyncSettings()
    private let overlaySettings = OverlaySettings()

    private var desktopWindow: DesktopWindow?
    private var statusItemController: StatusItemController?
    private var screenParameterObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no Cmd-Tab entry — belt-and-suspenders with `LSUIElement`.
        NSApplication.shared.setActivationPolicy(.accessory)

        let screenFrame = Self.currentScreenFrame()
        let window = DesktopWindow(contentRect: screenFrame)

        // `NSHostingView` sizes itself to its SwiftUI content's *fitting* size the moment
        // it's assigned as `contentView`, which would collapse this to a small corner
        // instead of the full screen. Giving it an explicit frame plus a flexible
        // autoresizing mask up front is what keeps it filling the window — both now and
        // across the screen-change resize below — without hardcoding a size into the
        // SwiftUI content itself (which wouldn't track a subsequent resize at all).
        let content = DesktopContentView(
            monitor: monitor, artwork: artwork, lyrics: lyrics,
            lyricsSyncSettings: lyricsSyncSettings, overlaySettings: overlaySettings)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: screenFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.setFrame(screenFrame, display: true)
        window.orderFrontRegardless()
        desktopWindow = window

        screenParameterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizeToCurrentScreen() }
        }

        statusItemController = StatusItemController(
            monitor: monitor, lyricsSyncSettings: lyricsSyncSettings, overlaySettings: overlaySettings)

        monitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The desktop window ignores mouse events and is never meant to be "closed" by
        // the user in the way a normal window is — losing it should not quit the app.
        false
    }

    deinit {
        if let screenParameterObserver {
            NotificationCenter.default.removeObserver(screenParameterObserver)
        }
    }

    private func resizeToCurrentScreen() {
        guard let window = desktopWindow else { return }
        // The content view's `[.width, .height]` autoresizing mask handles propagating
        // this to the SwiftUI content — no separate content-view resize needed.
        window.setFrame(Self.currentScreenFrame(), display: true)
    }

    private static func currentScreenFrame() -> NSRect {
        NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }
}
