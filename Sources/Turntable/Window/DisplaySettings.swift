import AppKit

/// Which physical display the overlay appears on. Persisted by the display's
/// `localizedName` rather than an index or `CGDirectDisplayID` — those can silently
/// renumber when a monitor is unplugged and reconnected in a different port order or a
/// different session, while the name a user picked from the menu stays recognizable (and,
/// for a given physical monitor, stable) across reboots.
@MainActor
final class DisplaySettings: ObservableObject {
    /// `nil` means "follow whichever screen macOS reports as main" — the default, and
    /// what keeps a single-display machine from ever needing this at all.
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
    /// back to `.main` rather than leaving the window stranded on a frame that no longer
    /// corresponds to any real display.
    func resolveScreen(from screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let screenName, let match = screens.first(where: { $0.localizedName == screenName }) else {
            return NSScreen.main
        }
        return match
    }
}
