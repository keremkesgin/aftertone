import Foundation

/// A persisted on/off switch for the lyrics column, independent of whether a `.lrc` was
/// found. Separate from `LyricsSyncSettings` (which only makes sense while lyrics are
/// showing) because "hide lyrics entirely" and "nudge lyrics timing" are different
/// questions with different UI lifetimes.
@MainActor
final class LyricsVisibilitySettings: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private static let defaultsKey = "dev.kesgin.Turntable.lyricsEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` (not `bool(forKey:)`) so a first launch — nothing stored yet
        // — defaults to shown, rather than `bool(forKey:)`'s built-in `false` default
        // silently hiding lyrics for every new user.
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func toggle() {
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.defaultsKey)
    }
}
