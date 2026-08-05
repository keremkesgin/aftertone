import Foundation

/// Playback state, normalized across providers.
enum PlaybackState: String, Equatable {
    /// The source application is not running. Never launch it to find out (spec §4.2).
    case notRunning
    case stopped
    case paused
    case playing

    var isPlaying: Bool { self == .playing }
}

/// A track, with every time value already in seconds.
///
/// Nothing in this type carries provider-specific units. Spotify reports `duration` in
/// milliseconds and `player position` in seconds; both are normalized inside
/// `SpotifyProvider` and raw values never escape it (spec §4.1).
struct Track: Equatable, Identifiable {
    /// Provider-scoped identity, e.g. `spotify:track:4uLU6hMCjMI75M1A2tKUQC`.
    /// Identity comes from here, never from title/artist — those repeat across releases.
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Seconds.
    let duration: TimeInterval
    let artworkURL: URL?
}

/// One observation of the source application. `position` is in seconds.
struct NowPlaying: Equatable {
    let state: PlaybackState
    let track: Track?
    let position: TimeInterval

    static let notRunning = NowPlaying(state: .notRunning, track: nil, position: 0)
    static let stopped = NowPlaying(state: .stopped, track: nil, position: 0)
}

/// Failures a provider surfaces to the UI. `procNotFound` is deliberately absent — a
/// source app quitting mid-poll is a benign race and maps to `.notRunning` (spec §12).
enum NowPlayingFailure: Error, Equatable {
    /// The user denied the Automation TCC prompt (OSStatus -1743). Needs a persistent,
    /// actionable banner — not a retry loop and not a modal per poll (spec §4.6).
    case automationDenied
    /// Anything else. Logged, shown once, not fatal.
    case providerError(code: Int, message: String)
}
