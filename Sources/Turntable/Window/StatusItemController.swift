import AppKit
import Combine

/// The only UI: a menu bar item showing what's playing (or why not), plus Quit.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let monitor: NowPlayingMonitor
    private var cancellable: AnyCancellable?

    private let nowPlayingItem = NSMenuItem()

    init(monitor: NowPlayingMonitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.grid.cross", accessibilityDescription: "Turntable")

        let menu = NSMenu()
        menu.addItem(nowPlayingItem)
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
        if let failure = monitor.failure {
            nowPlayingItem.title = Self.description(for: failure)
            nowPlayingItem.isEnabled = failure == .automationDenied
            nowPlayingItem.action = failure == .automationDenied ? #selector(openAutomationSettings) : nil
            nowPlayingItem.target = failure == .automationDenied ? self : nil
            return
        }
        nowPlayingItem.isEnabled = false
        nowPlayingItem.action = nil
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

    private static func description(for failure: NowPlayingFailure) -> String {
        switch failure {
        case .automationDenied: "Automation permission needed — click to open Settings…"
        case .providerError(_, let message): "Error: \(message)"
        }
    }

    @objc private func openAutomationSettings() {
        NowPlayingMonitor.openAutomationSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
