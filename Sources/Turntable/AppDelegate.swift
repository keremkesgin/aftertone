import AppKit
import Combine

/// Owns the app's lifecycle: polls Spotify, resolves artwork, and pushes it to the real
/// desktop wallpaper. The only UI is the menu bar item `StatusItemController` owns.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = NowPlayingMonitor()
    private lazy var artwork = ArtworkLoader(library: PlaceholderLibrary())
    private let wallpaper = WallpaperSetter()

    private var statusItemController: StatusItemController?
    private var cancellables: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no Cmd-Tab entry — belt-and-suspenders with `LSUIElement`.
        NSApplication.shared.setActivationPolicy(.accessory)

        cancellables.append(monitor.$snapshot.sink { [weak self] snapshot in
            self?.artwork.update(for: snapshot.track)
        })
        // Placeholders are filtered out here: this is what makes "nothing playing" leave
        // whatever's already on the desktop alone instead of overwriting it.
        cancellables.append(artwork.$state.sink { [weak self] state in
            guard let state, !state.isPlaceholder else { return }
            self?.wallpaper.apply(state)
        })

        statusItemController = StatusItemController(monitor: monitor)

        monitor.start()
    }
}
