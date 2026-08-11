import AppKit

/// Which physical display the overlay appears on. Persisted by the display's
/// `localizedName` rather than an index or `CGDirectDisplayID` — those can silently
/// renumber when a monitor is unplugged and reconnected in a different port order or a
/// different session, while the name a user picked from the menu stays recognizable (and,
/// for a given physical monitor, stable) across reboots.
@MainActor
final class DisplaySettings: ObservableObject {
    /// `nil` means "follow the primary display" — the default, and what keeps a
    /// single-display machine from ever needing this at all.
    @Published private(set) var screenName: String?

    private let defaults: UserDefaults
    private static let defaultsKey = "dev.kesgin.Turntable.displayName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenName = defaults.string(forKey: Self.defaultsKey)
    }

    func set(_ name: String?) {
        screenName = name
        if let name {
            defaults.set(name, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// Resolves the stored preference against the screens actually connected right now.
    /// A name that no longer matches anything — the chosen monitor got unplugged — falls
    /// back to the primary display rather than leaving the window stranded on a frame
    /// that no longer corresponds to any real display.
    ///
    /// Deliberately `screens.first`, not `NSScreen.main`: `.main` means "whichever screen
    /// currently has keyboard focus," which drifts as the user clicks between apps on
    /// different monitors — this app's window never takes focus, so `.main` would silently
    /// track focus changes elsewhere in the OS instead of staying on one fixed display.
    /// `NSScreen.screens.first` is, per Apple's documented ordering, always the display
    /// with the menu bar — the actual, stable meaning of "primary display."
    func resolveScreen(from screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        Self.resolveScreen(named: screenName, from: screens)
    }

    /// The name-taking variant exists for `$screenName` subscribers: `@Published` emits
    /// on `willSet`, so inside a sink the `screenName` *property* still holds the
    /// previous selection — resolving through the instance method there moves the window
    /// to the display the user picked last time, one selection behind. Subscribers must
    /// resolve the emitted name instead.
    static func resolveScreen(named name: String?, from screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let name, let match = screens.first(where: { $0.localizedName == name }) else {
            return screens.first
        }
        return match
    }
}
