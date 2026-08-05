import AppKit
import Combine

/// The only interaction surface for the app now that the main content ignores mouse
/// events (spec §9.1, trimmed to what's implemented so far — Artwork submenu and
/// Settings… are not wired up yet).
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let monitor: NowPlayingMonitor
    private weak var desktopWindow: NSWindow?
    private var cancellable: AnyCancellable?

    private let nowPlayingItem = NSMenuItem()
    private let toggleDeckItem = NSMenuItem()

    init(monitor: NowPlayingMonitor, desktopWindow: NSWindow) {
        self.monitor = monitor
        self.desktopWindow = desktopWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.grid.cross", accessibilityDescription: "Turntable")

        let menu = NSMenu()

        nowPlayingItem.isEnabled = false
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())

        toggleDeckItem.title = "Hide Deck"
        toggleDeckItem.action = #selector(toggleDeck)
        toggleDeckItem.target = self
        menu.addItem(toggleDeckItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Turntable", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        cancellable = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        switch monitor.snapshot.state {
        case .playing, .paused:
            if let track = monitor.snapshot.track {
                nowPlayingItem.title = "\(track.title) — \(track.artist)"
            }
        case .stopped:
            nowPlayingItem.title = "Nothing playing"
        case .notRunning:
            nowPlayingItem.title = "\(monitor.provider.sourceName) isn't running"
        }
    }

    @objc private func toggleDeck() {
        guard let desktopWindow else { return }
        let willShow = !desktopWindow.isVisible
        if willShow {
            desktopWindow.orderFrontRegardless()
        } else {
            desktopWindow.orderOut(nil)
        }
        toggleDeckItem.title = willShow ? "Hide Deck" : "Show Deck"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
