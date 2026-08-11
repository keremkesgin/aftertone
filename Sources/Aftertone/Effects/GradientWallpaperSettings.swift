import Foundation

/// Persisted on/off for `GradientWallpaperView`, same pattern as the other menu-bar
/// settings: a small `@MainActor` `ObservableObject` backed by `UserDefaults`.
@MainActor
final class GradientWallpaperSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private static let enabledKey = "dev.kesgin.Turntable.gradientWallpaperEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Off by default — replacing the user's visible wallpaper with a full-screen
        // fill is something they opt into, so `bool(forKey:)`'s "absent key reads as
        // false" is the wanted first-launch behavior.
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func toggle() {
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.enabledKey)
    }
}
