import AppKit
import Combine
import SwiftUI

/// Owns the app's lifecycle: polls Spotify, resolves artwork and lyrics, and renders them
/// in a click-through window at desktop level. The user's actual wallpaper is never
/// touched — `WallpaperSetter` is unused here, kept on disk for testing: gradient mode's
/// real-wallpaper mirroring (which fixes the menu bar scrim showing a pale band — see
/// `GradientWallpaperView`'s doc comment) is disabled while a wallpaper-restore issue is
/// being tested against, so the in-window gradient is the only visible effect again, same
/// as before that mirroring existed. Re-wire the block in `applicationDidFinishLaunching`
/// (and the `restoreOriginals()` call in `applicationWillTerminate`) to bring it back.
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
    private let lyricsVisibility = LyricsVisibilitySettings()
    private let overlaySettings = OverlaySettings()
    private let displaySettings = DisplaySettings()
    private let glowSettings = AlbumGlowSettings()
    private let vinylModeSettings = VinylModeSettings()
    private let gradientWallpaperSettings = GradientWallpaperSettings()
    private let wallpaperSetter = WallpaperSetter()
    private let updateChecker = UpdateChecker()

    private var desktopWindow: DesktopWindow?
    private var statusItemController: StatusItemController?
    private var screenParameterObserver: NSObjectProtocol?
    private var displaySettingsCancellable: AnyCancellable?
    private var gradientWallpaperCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no Cmd-Tab entry — belt-and-suspenders with `LSUIElement`.
        NSApplication.shared.setActivationPolicy(.accessory)

        let screenFrame = currentScreenFrame()
        let window = DesktopWindow(contentRect: screenFrame)

        // `NSHostingView` sizes itself to its SwiftUI content's *fitting* size the moment
        // it's assigned as `contentView`, which would collapse this to a small corner
        // instead of the full screen. Giving it an explicit frame plus a flexible
        // autoresizing mask up front is what keeps it filling the window — both now and
        // across the screen-change resize below — without hardcoding a size into the
        // SwiftUI content itself (which wouldn't track a subsequent resize at all).
        let content = DesktopContentView(
            monitor: monitor, artwork: artwork, lyrics: lyrics,
            lyricsSyncSettings: lyricsSyncSettings, lyricsVisibility: lyricsVisibility,
            overlaySettings: overlaySettings, glowSettings: glowSettings, vinylModeSettings: vinylModeSettings,
            gradientWallpaperSettings: gradientWallpaperSettings)
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
        // Picking a different display from the menu takes effect immediately, not on the
        // next actual screen-configuration change. Resolves the *emitted* name, not the
        // stored property — `@Published` emits on `willSet`, so reading the property
        // here would resize to the previously selected display, one pick behind.
        displaySettingsCancellable = displaySettings.$screenName.sink { [weak self] name in
            guard let self, let window = self.desktopWindow else { return }
            let frame = DisplaySettings.resolveScreen(named: name)?.frame
                ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            window.setFrame(frame, display: true)
        }

        // Real-wallpaper mirroring disabled for now — see the class doc comment above.
        // The commented block is exactly what to restore to bring it back:
        //
        // gradientWallpaperCancellable = Publishers
        //     .CombineLatest3(artwork.$state, artwork.$palette, gradientWallpaperSettings.$isEnabled)
        //     .sink { [weak self] state, palette, isEnabled in
        //         guard let self else { return }
        //         if isEnabled, let state, !state.isPlaceholder {
        //             self.wallpaperSetter.applyGradient(palette: palette, id: state.id)
        //         } else if !isEnabled {
        //             self.wallpaperSetter.restoreOriginals()
        //         }
        //     }

        statusItemController = StatusItemController(
            monitor: monitor, lyricsSyncSettings: lyricsSyncSettings, lyricsVisibility: lyricsVisibility,
            overlaySettings: overlaySettings, displaySettings: displaySettings, glowSettings: glowSettings,
            vinylModeSettings: vinylModeSettings, gradientWallpaperSettings: gradientWallpaperSettings,
            updateChecker: updateChecker)

        monitor.start()

        // One silent check per launch — a menu-bar utility that nags on every poll
        // would be worse than an app that's occasionally a version behind.
        updateChecker.checkSilently()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No-op while wallpaper mirroring is disabled — see the class doc comment.
        // Restore with: wallpaperSetter.restoreOriginals()
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
        window.setFrame(currentScreenFrame(), display: true)
    }

    private func currentScreenFrame() -> NSRect {
        displaySettings.resolveScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }
}
