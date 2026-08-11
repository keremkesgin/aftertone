import Foundation

/// Persisted on/off switch for Vinyl mode — the static record + sleeve visual that
/// replaces the badge/lyrics layout entirely and ignores `OverlaySettings.position`
/// (it's always centered, full-size).
@MainActor
final class VinylModeSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private static let defaultsKey = "dev.kesgin.Turntable.vinylModeEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func toggle() {
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.defaultsKey)
    }
}
