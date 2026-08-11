import AppKit
import Combine

/// The only UI: a menu bar item showing what's playing (or why not), a screen-position
/// submenu, a display-picker submenu, a Lyrics submenu (visibility + sync offset), a
/// Theme submenu (album-glow visibility + size), and Quit.
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
    private let glowSettings: AlbumGlowSettings
    private let vinylModeSettings: VinylModeSettings
    private let gradientWallpaperSettings: GradientWallpaperSettings
    private let updateChecker: UpdateChecker
    private var cancellables: [AnyCancellable] = []

    private let nowPlayingItem = NSMenuItem()
    private let syncOffsetItem = NSMenuItem()
    private let showLyricsItem = NSMenuItem()
    private let showGlowItem = NSMenuItem()
    private let glowSizeItem = NSMenuItem()
    private let vinylModeItem = NSMenuItem()
    private let gradientWallpaperItem = NSMenuItem()
    private let displayMenu = NSMenu()
    private var positionItems: [OverlayPosition: NSMenuItem] = [:]

    init(
        monitor: NowPlayingMonitor, lyricsSyncSettings: LyricsSyncSettings,
        lyricsVisibility: LyricsVisibilitySettings, overlaySettings: OverlaySettings,
        displaySettings: DisplaySettings, glowSettings: AlbumGlowSettings,
        vinylModeSettings: VinylModeSettings, gradientWallpaperSettings: GradientWallpaperSettings,
        updateChecker: UpdateChecker
    ) {
        self.monitor = monitor
        self.lyricsSyncSettings = lyricsSyncSettings
        self.lyricsVisibility = lyricsVisibility
        self.overlaySettings = overlaySettings
        self.displaySettings = displaySettings
        self.glowSettings = glowSettings
        self.vinylModeSettings = vinylModeSettings
        self.gradientWallpaperSettings = gradientWallpaperSettings
        self.updateChecker = updateChecker
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.grid.cross", accessibilityDescription: "Aftertone")

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

        let lyricsItem = NSMenuItem(title: "Lyrics", action: nil, keyEquivalent: "")
        lyricsItem.submenu = makeLyricsMenu()
        menu.addItem(lyricsItem)

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = makeThemeMenu()
        menu.addItem(themeItem)

        menu.addItem(.separator())

        vinylModeItem.title = "Vinyl Mode"
        vinylModeItem.action = #selector(toggleVinylMode)
        vinylModeItem.target = self
        menu.addItem(vinylModeItem)

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Aftertone", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Every sink below uses the *emitted* value, never a re-read of the property:
        // `@Published` publishes on `willSet`, so at emission time the property still
        // holds the previous value — re-reading it painted every checkmark one toggle
        // behind (toggle on → no checkmark; toggle off → checkmark appears). The
        // emitted value is the new one, and each publisher also replays the current
        // value on subscribe, which is what makes these both the initial paint and the
        // live update.
        cancellables.append(monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        cancellables.append(lyricsSyncSettings.$offset.sink { [weak self] offset in
            self?.refreshSyncOffsetLabel(offset)
        })
        cancellables.append(lyricsVisibility.$isEnabled.sink { [weak self] isEnabled in
            self?.showLyricsItem.state = isEnabled ? .on : .off
        })
        cancellables.append(overlaySettings.$position.sink { [weak self] position in
            self?.refreshPositionCheckmarks(selected: position)
        })
        cancellables.append(glowSettings.$isEnabled.sink { [weak self] isEnabled in
            self?.showGlowItem.state = isEnabled ? .on : .off
        })
        cancellables.append(glowSettings.$sizeScale.sink { [weak self] sizeScale in
            self?.refreshGlowSizeLabel(sizeScale)
        })
        cancellables.append(vinylModeSettings.$isEnabled.sink { [weak self] isEnabled in
            self?.vinylModeItem.state = isEnabled ? .on : .off
        })
        cancellables.append(gradientWallpaperSettings.$isEnabled.sink { [weak self] isEnabled in
            self?.gradientWallpaperItem.state = isEnabled ? .on : .off
        })
        refresh()
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

    private func makeLyricsMenu() -> NSMenu {
        let submenu = NSMenu()

        showLyricsItem.title = "Show Lyrics"
        showLyricsItem.action = #selector(toggleLyricsVisibility)
        showLyricsItem.target = self
        submenu.addItem(showLyricsItem)

        submenu.addItem(.separator())

        syncOffsetItem.isEnabled = false
        submenu.addItem(syncOffsetItem)

        let earlierItem = NSMenuItem(
            title: "Show Lyrics Earlier", action: #selector(nudgeEarlier), keyEquivalent: "[")
        earlierItem.target = self
        submenu.addItem(earlierItem)

        let laterItem = NSMenuItem(
            title: "Show Lyrics Later", action: #selector(nudgeLater), keyEquivalent: "]")
        laterItem.target = self
        submenu.addItem(laterItem)

        let resetItem = NSMenuItem(
            title: "Reset Lyrics Sync", action: #selector(resetSync), keyEquivalent: "")
        resetItem.target = self
        submenu.addItem(resetItem)

        return submenu
    }

    private func makeThemeMenu() -> NSMenu {
        let submenu = NSMenu()

        showGlowItem.title = "Show Theme Glow"
        showGlowItem.action = #selector(toggleGlowVisibility)
        showGlowItem.target = self
        submenu.addItem(showGlowItem)

        gradientWallpaperItem.title = "Gradient Wallpaper"
        gradientWallpaperItem.action = #selector(toggleGradientWallpaper)
        gradientWallpaperItem.target = self
        submenu.addItem(gradientWallpaperItem)

        submenu.addItem(.separator())

        glowSizeItem.isEnabled = false
        submenu.addItem(glowSizeItem)

        let increaseItem = NSMenuItem(
            title: "Increase Glow Size", action: #selector(increaseGlowSize), keyEquivalent: "=")
        increaseItem.target = self
        submenu.addItem(increaseItem)

        let decreaseItem = NSMenuItem(
            title: "Decrease Glow Size", action: #selector(decreaseGlowSize), keyEquivalent: "-")
        decreaseItem.target = self
        submenu.addItem(decreaseItem)

        let resetItem = NSMenuItem(
            title: "Reset Glow Size", action: #selector(resetGlowSize), keyEquivalent: "")
        resetItem.target = self
        submenu.addItem(resetItem)

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

    private func refreshSyncOffsetLabel(_ offset: Double) {
        syncOffsetItem.title = String(format: "Lyrics sync: %+.2fs", offset)
    }

    private func refreshPositionCheckmarks(selected: OverlayPosition) {
        for (position, item) in positionItems {
            item.state = position == selected ? .on : .off
        }
    }

    private func refreshGlowSizeLabel(_ sizeScale: Double) {
        glowSizeItem.title = String(format: "Theme size: %.0f%%", sizeScale * 100)
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

    @objc private func toggleGlowVisibility() {
        glowSettings.toggle()
    }

    @objc private func increaseGlowSize() {
        glowSettings.increaseSize()
    }

    @objc private func decreaseGlowSize() {
        glowSettings.decreaseSize()
    }

    @objc private func resetGlowSize() {
        glowSettings.resetSize()
    }

    @objc private func toggleVinylMode() {
        vinylModeSettings.toggle()
    }

    @objc private func toggleGradientWallpaper() {
        gradientWallpaperSettings.toggle()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkAndAnnounce()
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
