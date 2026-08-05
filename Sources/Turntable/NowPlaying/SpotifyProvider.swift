import Foundation

/// Reads now-playing state from the Spotify desktop client over its public AppleScript
/// interface (spec §4). Not MediaRemote: as of macOS 15.4 the private framework is
/// entitlement-gated and returns nothing to third-party apps.
/// `@unchecked Sendable`: every stored property is `let`, and the one thing that looks
/// mutable from outside — `NSAppleScript.executeAndReturnError`'s internal state — is only
/// ever touched from `pollQueue`, serially. Nothing here is actually shared mutable state.
final class SpotifyProvider: NowPlayingProvider, @unchecked Sendable {
    static let bundleID = "com.spotify.client"

    let sourceName = "Spotify"

    /// ASCII 0x01. Cannot appear in track metadata, so no escaping is needed and a
    /// single Apple Event carries the whole snapshot.
    private static let delimiter: Character = "\u{01}"

    private static let notRunningSentinel = "notrunning"
    private static let stoppedSentinel = "stopped"

    // MARK: - Script

    /// One delimited line per poll — one Apple Event, not eight.
    ///
    /// `application id "…" is running` is the form that does *not* launch Spotify; a bare
    /// `tell application "Spotify"` would (spec §4.2). `artwork url` is wrapped in `try`
    /// because it throws for some local files.
    ///
    /// Variable naming is not free here: `st` — which spec §4.3 uses — is a reserved
    /// AppleScript term, and `set st to …` fails to compile with error -2741 ("Expected
    /// expression but found “st”") even outside a tell block. Verified `tk`, `art` and `d`
    /// are safe.
    private static let source = """
    if application id "\(SpotifyProvider.bundleID)" is running then
        tell application id "\(SpotifyProvider.bundleID)"
            set playerState to player state as text
            if playerState is "\(SpotifyProvider.stoppedSentinel)" then return "\(SpotifyProvider.stoppedSentinel)"
            set tk to current track
            set art to ""
            try
                set art to (artwork url of tk) as text
            end try
            set d to (ASCII character 1)
            return playerState & d & (id of tk) & d & (name of tk) & d & (artist of tk) & d ¬
                & (album of tk) & d & ((duration of tk) as text) & d ¬
                & ((player position) as text) & d & art
        end tell
    else
        return "\(SpotifyProvider.notRunningSentinel)"
    end if
    """

    /// Compiled once and reused. Recompiling per poll is ~10x the cost (spec §4.4).
    private let script: NSAppleScript?
    /// A script that will not compile is a programming error, but crashing on launch is a
    /// worse failure than a banner the user can read. Report it like any other fault.
    private let compileFailure: NowPlayingFailure?

    /// Every `executeAndReturnError` call is confined to this single serial queue, and
    /// nothing else touches `script`. That satisfies the one thread-safety property
    /// `NSAppleScript` actually needs — calls never overlap in time — without requiring
    /// them to land on the *main* thread, which spec §4.4 asks for but which measurement
    /// shows is the wrong place for an 80-90ms Apple Event round trip.
    private let pollQueue = DispatchQueue(label: "dev.kesgin.Turntable.spotify-poll")

    init() {
        guard let script = NSAppleScript(source: Self.source) else {
            self.script = nil
            self.compileFailure = .providerError(code: -1, message: "Polling script could not be constructed.")
            return
        }
        var error: NSDictionary?
        if script.compileAndReturnError(&error) {
            self.script = script
            self.compileFailure = nil
        } else {
            self.script = nil
            self.compileFailure = Self.failure(from: error ?? [:])
                ?? .providerError(code: -2, message: "Polling script could not be compiled.")
        }
    }

    // MARK: - Polling

    func poll() async throws -> NowPlaying {
        try await withCheckedThrowingContinuation { continuation in
            pollQueue.async { [self] in
                continuation.resume(with: Result { try self.pollSynchronously() })
            }
        }
    }

    /// The actual `NSAppleScript` round trip. Only ever called from `pollQueue` — never
    /// concurrently, never on the main thread.
    private func pollSynchronously() throws -> NowPlaying {
        dispatchPrecondition(condition: .onQueue(pollQueue))

        if let compileFailure { throw compileFailure }
        guard let script else { return .notRunning }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error {
            // A nil failure means the condition is benign — Spotify quit mid-poll — and
            // must not surface as an error the user sees (spec §12).
            guard let failure = Self.failure(from: error) else { return .notRunning }
            throw failure
        }
        guard let line = descriptor.stringValue else {
            // Executed cleanly but returned nothing coercible. Treat as no source rather
            // than an error the user has to look at.
            return .notRunning
        }
        return Self.parse(line)
    }

    /// Maps an `NSAppleScript` error dictionary onto our failure model, or `nil` when the
    /// condition is benign and the caller should treat it as "source not running".
    ///
    /// Returns `nil` for:
    /// - `-600` / `-609` / `-1728`: Spotify quit or lost its `current track` mid-poll.
    ///   A race, not a fault (spec §12).
    ///
    /// Internal rather than private so `SelfTest` can exercise the mapping without needing
    /// the user to actually deny a TCC prompt.
    static func failure(from error: NSDictionary) -> NowPlayingFailure? {
        let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
        let message = (error["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error \(code)"

        switch code {
        case errAEEventNotPermitted:
            return .automationDenied
        case procNotFound, connectionInvalid, errAENoSuchObject:
            return nil
        default:
            return .providerError(code: code, message: message)
        }
    }

    // MARK: - Parsing

    /// The only place Spotify's units and identity format exist. Everything downstream
    /// sees seconds and a `Track` (spec §4.1, §14).
    static func parse(_ line: String) -> NowPlaying {
        if line == notRunningSentinel { return .notRunning }
        if line == stoppedSentinel { return .stopped }

        let fields = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 8 else { return .notRunning }

        let state: PlaybackState
        switch fields[0] {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": return .stopped
        default: return .notRunning
        }

        // duration: milliseconds → seconds. position: already seconds.
        let duration = (number(fields[5]) ?? 0) / 1000.0
        let position = number(fields[6]) ?? 0

        let track = Track(
            id: fields[1],
            title: fields[2],
            artist: fields[3],
            album: fields[4],
            duration: max(0, duration),
            artworkURL: artworkURL(from: fields[7])
        )
        return NowPlaying(state: state, track: track, position: max(0, position))
    }

    /// Locale-independent numeric parse. AppleScript renders reals with the *user's*
    /// decimal separator, so `player position` can arrive as "12,345" on e.g. a Turkish
    /// or German system. `Double("12,345")` returns nil, which would silently pin the
    /// tonearm at 0 — so normalize the separator before parsing.
    private static func number(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) { return value }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Spotify returns "" for local files (the `try` in the script swallowed the throw),
    /// and has historically returned an `i.scdn.co` URL that 404s. Only http(s) URLs are
    /// worth handing to the artwork loader; everything else falls back to a placeholder.
    private static func artworkURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "missing value",
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
