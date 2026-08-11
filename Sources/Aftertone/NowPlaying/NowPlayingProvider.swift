import Foundation

/// A source of now-playing state.
///
/// This abstraction is the insurance policy (spec §14): Spotify's AppleScript interface
/// has broken across client updates, so the rest of the app must never see it. Anything
/// provider-specific — unit conversions, error codes, identity formats — stops here.
protocol NowPlayingProvider: AnyObject {
    /// Human-readable source name, e.g. "Spotify". Used in failure copy.
    var sourceName: String { get }

    /// Read current state. Must not launch the source application if it is not running.
    ///
    /// Spec §4.4 says this "costs well under a millisecond of main-thread time" and calls
    /// for running it synchronously on the main thread. Measured against the live client
    /// (`make bench`), a full-fidelity poll costs **80-90ms** — the Apple Event round trip
    /// to Spotify, not anything on our side — which would drop 5+ consecutive 60fps frames
    /// once per second if it ran on the main thread as specced. `async` here is that
    /// correction: implementations confine the actual `NSAppleScript` call to a private
    /// background queue so the cost lands off the render thread entirely.
    func poll() async throws -> NowPlaying
}
