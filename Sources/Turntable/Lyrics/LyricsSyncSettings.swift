import Foundation

/// A user-adjustable global offset applied to the playback position before it's used to
/// pick the active lyric line. No amount of polling accuracy fixes what this compensates
/// for: a community-sourced `.lrc` can itself be biased by a few hundred milliseconds, and
/// that bias is a property of the *file*, not something `PlaybackClock` can detect or
/// correct. A manual nudge — the same feature Musixmatch and Apple Music both ship — is
/// the standard fix.
@MainActor
final class LyricsSyncSettings: ObservableObject {
    /// Seconds added to the reported position before looking up the active line. Positive
    /// makes lyrics advance *earlier* (use this when lyrics are showing late, i.e. the
    /// song is ahead of the highlighted line); negative delays them.
    @Published private(set) var offset: TimeInterval

    /// Cheap insurance against fat-fingering the menu item repeatedly into something the
    /// UI no longer meaningfully explains ("why are my lyrics 40 seconds off").
    static let range: ClosedRange<TimeInterval> = -5...5
    private static let step: TimeInterval = 0.25
    private static let defaultsKey = "dev.kesgin.Turntable.lyricsSyncOffsetSeconds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.defaultsKey)
        offset = Self.range.contains(stored) ? stored : 0
    }

    private let defaults: UserDefaults

    func nudgeEarlier() { set(offset + Self.step) }
    func nudgeLater() { set(offset - Self.step) }
    func reset() { set(0) }

    private func set(_ value: TimeInterval) {
        offset = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        defaults.set(offset, forKey: Self.defaultsKey)
    }
}
