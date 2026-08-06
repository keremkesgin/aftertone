import AppKit
import Combine

/// The only UI: a menu bar item showing what's playing (or why not), a screen-position
/// submenu, a display-picker submenu, lyrics visibility + sync-offset controls, and Quit.
///
/// `NSObject` subclass (not a plain Swift class, unlike everything else in this app) is
/// required here specifically: `NSMenuDelegate` inherits from `NSObjectProtocol`, and the
/// display submenu needs that delegate to rebuild itself against whatever monitors are
/// actually connected each time it's opened, rather than a snapshot taken once at launch.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let monitor: NowPlayingMonitor
    private let lyricsSyncSettings: LyricsSyncSettings
    private let lyricsVisibility: LyricsVisibilitySettings
    private let overlaySettings: OverlaySettings
    private let displaySettings: DisplaySettings
    private var cancellables: [AnyCancellable] = []

    private let nowPlayingItem = NSMenuItem()
    private let syncOffsetItem = NSMenuItem()
    private let showLyricsItem = NSMenuItem()
    private let displayMenu = NSMenu()
    private var positionItems: [OverlayPosition: NSMenuItem] = [:]

    init(
        monitor: NowPlayingMonitor, lyricsSyncSettings: LyricsSyncSettings,
        lyricsVisibility: LyricsVisibilitySettings, overlaySettings: OverlaySettings,
        displaySettings: DisplaySettings
    ) {
        self.monitor = monitor
        self.lyricsSyncSettings = lyricsSyncSettings
        self.lyricsVisibility = lyricsVisibility
        self.overlaySettings = overlaySettings
        self.displaySettings = displaySettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.grid.cross", accessibilityDescription: "Turntable")

        let menu = NSMenu()
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())

        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionItem.submenu = makePositionMenu()
        menu.addItem(positionItem)

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayMenu.delegate = self
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(.separator())

        showLyricsItem.title = "Show Lyrics"
        showLyricsItem.action = #selector(toggleLyricsVisibility)
        showLyricsItem.target = self
        menu.addItem(showLyricsItem)

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
        cancellables.append(lyricsVisibility.$isEnabled.sink { [weak self] _ in
            self?.refreshLyricsVisibilityCheckmark()
        })
        cancellables.append(overlaySettings.$position.sink { [weak self] _ in
            self?.refreshPositionCheckmarks()
        })
        refresh()
        refreshSyncOffsetLabel()
        refreshLyricsVisibilityCheckmark()
        refreshPositionCheckmarks()
    }

    /// One checkable item per `OverlayPosition`, in display order. Unlike the display
    /// submenu, the set of positions never changes at runtime, so this is built once.
    private func makePositionMenu() -> NSMenu {
        let submenu = NSMenu()
        for position in OverlayPosition.allCases {
            let item = NSMenuItem(
                title: position.displayName, action: #selector(selectPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position
            submenu.addItem(item)
            positionItems[position] = item
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

    private func refreshLyricsVisibilityCheckmark() {
        showLyricsItem.state = lyricsVisibility.isEnabled ? .on : .off
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? OverlayPosition else { return }
        overlaySettings.set(position)
    }

    @objc private func toggleLyricsVisibility() {
        lyricsVisibility.toggle()
    }

    /// `nil` represented object means "Main Display" — follow whatever macOS reports as
    /// main, rather than pinning to one that could later become disconnected.
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        displaySettings.set(sender.representedObject as? String)
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

extension StatusItemController: NSMenuDelegate {
    /// Rebuilds the Display submenu against whatever's connected *right now*, every time
    /// it's about to open — monitors get plugged and unplugged far more often over an
    /// app's lifetime than the fixed set of `OverlayPosition` cases ever changes, so this
    /// can't be a one-time build like `makePositionMenu()`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === displayMenu else { return }
        menu.removeAllItems()

        let mainItem = NSMenuItem(title: "Main Display", action: #selector(selectDisplay(_:)), keyEquivalent: "")
        mainItem.target = self
        mainItem.representedObject = nil as String?
        mainItem.state = displaySettings.screenName == nil ? .on : .off
        menu.addItem(mainItem)

        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        menu.addItem(.separator())
        for screen in screens {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = displaySettings.screenName == name ? .on : .off
            menu.addItem(item)
        }
    }
}
