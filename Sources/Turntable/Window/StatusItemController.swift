import AppKit
import Combine

/// The only UI: a menu bar item showing what's playing (or why not), a lyrics sync-offset
/// nudge, a screen-position submenu, and Quit.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let monitor: NowPlayingMonitor
    private let lyricsSyncSettings: LyricsSyncSettings
    private let overlaySettings: OverlaySettings
    private var cancellables: [AnyCancellable] = []

    private let nowPlayingItem = NSMenuItem()
    private let syncOffsetItem = NSMenuItem()
    private var positionItems: [OverlayPosition: NSMenuItem] = [:]

    init(monitor: NowPlayingMonitor, lyricsSyncSettings: LyricsSyncSettings, overlaySettings: OverlaySettings) {
        self.monitor = monitor
        self.lyricsSyncSettings = lyricsSyncSettings
        self.overlaySettings = overlaySettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.grid.cross", accessibilityDescription: "Turntable")

        let menu = NSMenu()
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())

        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionItem.submenu = Self.makePositionMenu(target: self, items: &positionItems)
        menu.addItem(positionItem)

        menu.addItem(.separator())

        syncOffsetItem.isEnabled = false
        menu.addItem(syncOffsetItem)

        let earlierItem = NSMenuItem(
            title: "Show Lyrics Earlier", action: #selector(nudgeEarlier), keyEquivalent: "[")
        earlierItem.target = self
        menu.addItem(earlierItem)

        let laterItem = NSMenuItem(
            title: "Show Lyrics Later", action: #selector(nudgeLater), keyEquivalent: "]")
        laterItem.target = self
        menu.addItem(laterItem)

        let resetItem = NSMenuItem(
            title: "Reset Lyrics Sync", action: #selector(resetSync), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Turntable", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        cancellables.append(monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        cancellables.append(lyricsSyncSettings.$offset.sink { [weak self] _ in
            self?.refreshSyncOffsetLabel()
        })
        cancellables.append(overlaySettings.$position.sink { [weak self] _ in
            self?.refreshPositionCheckmarks()
        })
        refresh()
        refreshSyncOffsetLabel()
        refreshPositionCheckmarks()
    }

    /// Built once at init: one checkable item per `OverlayPosition`, in display order.
    /// `items` is filled in as an out-param so the caller can update checkmarks later
    /// without walking the submenu back apart.
    private static func makePositionMenu(
        target: StatusItemController, items: inout [OverlayPosition: NSMenuItem]
    ) -> NSMenu {
        let submenu = NSMenu()
        for position in OverlayPosition.allCases {
            let item = NSMenuItem(
                title: position.displayName, action: #selector(StatusItemController.selectPosition(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = position
            submenu.addItem(item)
            items[position] = item
        }
        return submenu
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

    private func refreshSyncOffsetLabel() {
        syncOffsetItem.title = String(format: "Lyrics sync: %+.2fs", lyricsSyncSettings.offset)
    }

    private func refreshPositionCheckmarks() {
        for (position, item) in positionItems {
            item.state = position == overlaySettings.position ? .on : .off
        }
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? OverlayPosition else { return }
        overlaySettings.set(position)
    }

    @objc private func nudgeEarlier() {
        lyricsSyncSettings.nudgeEarlier()
    }

    @objc private func nudgeLater() {
        lyricsSyncSettings.nudgeLater()
    }

    @objc private func resetSync() {
        lyricsSyncSettings.reset()
    }

    @objc private func openAutomationSettings() {
        NowPlayingMonitor.openAutomationSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
