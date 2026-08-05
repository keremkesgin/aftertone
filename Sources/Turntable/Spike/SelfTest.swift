import Foundation

/// Deterministic tests for the parse boundary and error mapping.
///
/// This exists instead of an XCTest target because the machine has Command Line Tools but
/// no Xcode, and `XCTest.framework` ships with Xcode — `swift test` cannot link. Run with
/// `make test`; it exits non-zero on failure, so it is CI-usable as-is. Move to
/// swift-testing if a full Xcode gets installed.
enum SelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    static func run() -> Never {
        parsing()
        errorMapping()

        print("")
        if failures.isEmpty {
            print("✓ \(checks) checks passed")
            exit(0)
        }
        print("✗ \(failures.count) of \(checks) checks failed:")
        for failure in failures { print("   · \(failure)") }
        exit(1)
    }

    // MARK: - Harness

    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual != expected { failures.append("\(label): got \(actual), expected \(expected)") }
    }

    private static func expectClose(
        _ actual: Double, _ expected: Double, _ tolerance: Double, _ label: String
    ) {
        checks += 1
        if abs(actual - expected) > tolerance {
            failures.append("\(label): got \(actual), expected \(expected) ±\(tolerance)")
        }
    }

    private static func line(
        state: String = "playing",
        id: String = "spotify:track:2tudvzsrR56uom6smgOcSf",
        title: String = "Like That",
        artist: String = "Future",
        album: String = "WE DON'T TRUST YOU",
        durationMS: String = "267706",
        position: String = "90.271",
        artwork: String = "https://i.scdn.co/image/ab67616d0000b273cec3fc072352b5f4f637d9fa"
    ) -> String {
        [state, id, title, artist, album, durationMS, position, artwork].joined(separator: "\u{01}")
    }

    // MARK: - Parsing (spec §4.1, §12)

    private static func parsing() {
        print("parse boundary")

        expectEqual(SpotifyProvider.parse("notrunning").state, .notRunning, "notrunning sentinel")
        expectEqual(SpotifyProvider.parse("stopped").state, .stopped, "stopped sentinel")

        let playing = SpotifyProvider.parse(line())
        expectEqual(playing.state, .playing, "playing state")
        expectEqual(playing.track?.title, "Like That", "title")
        expectEqual(playing.track?.artist, "Future", "artist")
        expectEqual(playing.track?.album, "WE DON'T TRUST YOU", "album")
        expectEqual(playing.track?.id, "spotify:track:2tudvzsrR56uom6smgOcSf", "id")
        // 267706 ms must arrive as seconds. This is the gotcha in spec §4.1.
        expectClose(playing.track?.duration ?? 0, 267.706, 0.001, "duration ms → s")
        expectClose(playing.position, 90.271, 0.001, "position already in seconds")

        // Real output on this machine was "90,271003723145" — AppleScript renders reals
        // with the user's decimal separator, and Double() rejects a comma.
        let commaLocale = SpotifyProvider.parse(line(position: "90,271003723145"))
        expectClose(commaLocale.position, 90.271, 0.001, "decimal-comma position")
        let commaDuration = SpotifyProvider.parse(line(durationMS: "267706,0"))
        expectClose(commaDuration.track?.duration ?? 0, 267.706, 0.001, "decimal-comma duration")

        expectEqual(SpotifyProvider.parse(line(state: "paused")).state, .paused, "paused state")
        // A "stopped" state arriving on a full line still means stopped.
        expectEqual(SpotifyProvider.parse(line(state: "stopped")).state, .stopped, "stopped on full line")
        expectEqual(SpotifyProvider.parse(line(state: "nonsense")).state, .notRunning, "unknown state")

        // Local file: the script's `try` swallowed the throw and left "".
        expect(SpotifyProvider.parse(line(artwork: "")).track?.artworkURL == nil, "empty artwork url → nil")
        expect(SpotifyProvider.parse(line(artwork: "missing value")).track?.artworkURL == nil,
               "missing value artwork → nil")
        expect(SpotifyProvider.parse(line(artwork: "file:///tmp/x.jpg")).track?.artworkURL == nil,
               "non-http artwork scheme rejected")
        expect(SpotifyProvider.parse(line()).track?.artworkURL != nil, "https artwork accepted")

        // Malformed input must degrade, never crash (spec §12).
        expectEqual(SpotifyProvider.parse("").state, .notRunning, "empty line")
        expectEqual(SpotifyProvider.parse("playing\u{01}only-two").state, .notRunning, "too few fields")
        expectEqual(SpotifyProvider.parse(line() + "\u{01}extra").state, .notRunning, "too many fields")
        expectEqual(SpotifyProvider.parse(line(durationMS: "abc", position: "xyz")).track?.duration, 0,
                    "unparseable duration → 0")

        // Ads: Spotify reports odd metadata. Keep the track, let the scene show a
        // placeholder and keep spinning (spec §12).
        let advert = SpotifyProvider.parse(
            line(id: "spotify:ad:1", title: "Advertisement", artist: "", album: "", durationMS: "0", artwork: ""))
        expectEqual(advert.state, .playing, "ad still reports playing")
        expectEqual(advert.track?.duration, 0, "ad zero duration tolerated")

        // Negative position has been observed on track transitions; must not go negative.
        expectEqual(SpotifyProvider.parse(line(position: "-3.5")).position, 0, "negative position clamped")
    }

    // MARK: - Error mapping (spec §4.6, §12)

    private static func errorMapping() {
        print("error mapping")

        func mapped(_ code: Int) -> NowPlayingFailure? {
            SpotifyProvider.failure(from: [
                "NSAppleScriptErrorNumber": code,
                "NSAppleScriptErrorMessage": "synthetic \(code)",
            ] as NSDictionary)
        }

        // A denial must reach the menu bar label, not be swallowed as a generic error.
        expectEqual(mapped(-1743), .automationDenied, "-1743 → automationDenied")
        // Benign races map to nil, i.e. "treat as not running", not to a visible error.
        expect(mapped(-600) == nil, "-600 procNotFound is benign")
        expect(mapped(-609) == nil, "-609 connectionInvalid is benign")
        expect(mapped(-1728) == nil, "-1728 no such object is benign")
        // Anything else is a real, reportable fault.
        expectEqual(mapped(-1712), .providerError(code: -1712, message: "synthetic -1712"),
                    "-1712 timeout → providerError")
    }
}
