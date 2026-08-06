import AppKit
import Foundation

/// Deterministic tests for the parse boundary, error mapping, the playback clock, and
/// lyrics parsing/matching.
///
/// This exists instead of an XCTest target because the machine has Command Line Tools but
/// no Xcode, and `XCTest.framework` ships with Xcode — `swift test` cannot link. Run with
/// `make test`; it exits non-zero on failure, so it is CI-usable as-is. Move to
/// swift-testing if a full Xcode gets installed.
///
/// `@MainActor`: `lyricsSyncSettings()`/`overlaySettings()` construct `@MainActor`
/// settings types. `run()` is always entered via `MainActor.assumeIsolated { ... }` in
/// `main.swift`, so this adds no new isolation requirement at the call site.
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    static func run() -> Never {
        parsing()
        errorMapping()
        clock()
        lrc()
        lyricsDocument()
        wordFill()
        lyricsStoreMatching()
        lyricsFetcherRequestURL()
        lyricsSyncSettings()
        overlaySettings()
        lyricsVisibilitySettings()
        displaySettings()

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

    // MARK: - Clock

    private static func clock() {
        print("playback clock")

        let clock = PlaybackClock()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let frame = 1.0 / 30.0

        /// Run `count` display frames forward from `origin`.
        func advance(_ clock: PlaybackClock, from origin: Date, frames count: Int) -> Date {
            var now = origin
            for _ in 0..<count {
                now = now.addingTimeInterval(frame)
                clock.advance(to: now)
            }
            return now
        }

        // A new track id snaps, never interpolates across the boundary.
        clock.sync(to: 10, trackID: "a", isPlaying: true)
        expectEqual(clock.position, 10, "first sync snaps")
        expectEqual(clock.lastSyncKind, .snapped, "first sync reported as snap")

        // The first frame after a sync only establishes the timing baseline — there is no
        // previous timestamp to measure a delta against, so it contributes 0.
        expectEqual(clock.advance(to: start), 0, "baseline frame contributes no time")

        // One second of frames while playing advances one second.
        var now = advance(clock, from: start, frames: 30)
        expectClose(clock.position, 11.0, 0.02, "30 frames = +1s while playing")

        // A drift under 50ms is noise; correcting it would be visible jitter.
        clock.sync(to: clock.position + 0.02, trackID: "a", isPlaying: true)
        expectEqual(clock.lastSyncKind, .ignored, "sub-50ms drift ignored")
        expectEqual(clock.residualDrift, 0, "ignored drift leaves no residual")

        // A drift between 50ms and 1.5s eases in.
        let beforeEase = clock.position
        clock.sync(to: beforeEase + 0.4, trackID: "a", isPlaying: true)
        expectEqual(clock.lastSyncKind, .eased, "0.4s drift eased")
        expect(clock.residualDrift > 0.39, "eased drift is queued as residual")
        // Acceptance: re-converge within ~0.5s. 15 frames at 30fps is 0.5s, by which point
        // 0.75^15 = 1.3% of the error is left — 5ms of audio position, far below anything
        // perceivable in a lyric highlight.
        now = advance(clock, from: now, frames: 15)
        expect(abs(clock.residualDrift) < 0.01, "≥97% of drift absorbed within 0.5s")
        expectClose(clock.position, beforeEase + 0.4 + 0.5, 0.03, "eased position lands on truth")
        // And it does settle to exactly zero a few frames later.
        now = advance(clock, from: now, frames: 3)
        expectEqual(clock.residualDrift, 0, "drift fully absorbed shortly after")

        // A scrub is beyond any plausible drift: snap.
        clock.sync(to: 200, trackID: "a", isPlaying: true)
        expectEqual(clock.lastSyncKind, .snapped, "scrub >1.5s snaps")
        expectEqual(clock.position, 200, "snap lands exactly")

        // Track change snaps even when the reported position is close to the current one.
        clock.sync(to: 200.1, trackID: "b", isPlaying: true)
        expectEqual(clock.lastSyncKind, .snapped, "track change snaps regardless of drift size")

        // Display sleep: a huge frame delta must be clamped to one frame's worth, or the
        // active lyric line jumps unpredictably on wake.
        let beforeSleep = clock.position
        clock.advance(to: now.addingTimeInterval(600))
        expectClose(clock.position, beforeSleep + 0.1, 0.001, "600s gap clamped to 0.1s")

        // Paused: frames must not advance position.
        clock.sync(to: 50, trackID: "b", isPlaying: false)
        _ = advance(clock, from: start, frames: 30)
        expectEqual(clock.position, 50, "paused clock does not advance")

        // Duration 0 (ads, some podcast episodes) must not divide by zero.
        expectEqual(clock.progress(duration: 0), 0, "zero duration → progress 0")
        expectEqual(clock.progress(duration: 10), 1.0, "progress clamped to 1")
        expectEqual(clock.progress(duration: 200), 0.25, "progress fraction")

        // resetFrameTiming drops the accumulated timestamp, so the next frame is a no-op.
        clock.sync(to: 10, trackID: "b", isPlaying: true)
        clock.resetFrameTiming()
        expectEqual(clock.advance(to: now.addingTimeInterval(5)), 0, "first frame after reset is free")
        expectEqual(clock.position, 10, "position unchanged by the reset frame")
    }

    // MARK: - LRC parsing

    private static func lrc() {
        print("LRC parsing")

        let standard = """
        [ti:Test Song]
        [ar:Test Artist]
        [al:Test Album]
        [offset:-500]

        [00:12.34]Line one
        [00:15.00]Line two
        [00:15.00][00:20.00]Repeated chorus
        [00:12.34]Line one
        [not a timestamp]stray bracket text, not a lyric line
        """
        let doc = LRCParser.parse(standard)

        expectEqual(doc.title, "Test Song", "[ti:] parsed")
        expectEqual(doc.artist, "Test Artist", "[ar:] parsed")
        expectEqual(doc.album, "Test Album", "[al:] parsed")

        // offset -500ms applies to every timestamp.
        expectClose(doc.lines.first(where: { $0.text == "Line one" })?.start ?? -1, 11.84, 0.001,
                    "offset applied: 12.34 - 0.5 = 11.84")

        // Multi-timestamp line produces two entries sharing text, both offset.
        let chorus = doc.lines.filter { $0.text == "Repeated chorus" }
        expectEqual(chorus.count, 2, "a [t1][t2]text line produces two entries")
        expectClose(chorus.map(\.start).min() ?? -1, 14.5, 0.001, "first chorus timestamp offset")
        expectClose(chorus.map(\.start).max() ?? -1, 19.5, 0.001, "second chorus timestamp offset")

        // Exact duplicate (same start, same text) is deduped to one entry.
        let lineOnes = doc.lines.filter { $0.text == "Line one" }
        expectEqual(lineOnes.count, 1, "an exact (start, text) duplicate is deduped to one entry")

        // A same-start, different-text collision (Line two vs. the first chorus entry,
        // both landing at 14.5 after offset) must NOT be deduped against each other.
        expect(doc.lines.contains(where: { $0.text == "Line two" }), "same-start-different-text line survives")

        // Stray bracket text that isn't a real timestamp or metadata tag: skipped, no crash.
        expect(!doc.lines.contains(where: { $0.text.contains("stray bracket") }), "malformed line skipped")

        expectEqual(doc.lines, doc.lines.sorted(by: { $0.start < $1.start }), "lines end up sorted by start")

        // Enhanced (word-level) LRC.
        let enhanced = LRCParser.parse("[00:12.34]<00:12.34>Word <00:12.80>by <00:13.10>word")
        expectEqual(enhanced.lines.count, 1, "one enhanced line parsed")
        let words = enhanced.lines.first?.words
        expectEqual(words?.count, 3, "three words parsed")
        expectEqual(enhanced.lines.first?.text, "Word by word", "line text is the word concatenation")
        expectClose(words?[0].start ?? -1, 12.34, 0.001, "word 1 start")
        expectClose(words?[1].start ?? -1, 12.80, 0.001, "word 2 start")
        expectClose(words?[2].start ?? -1, 13.10, 0.001, "word 3 start")

        // Standard lines have `words == nil` — this is how the view tells the two forms
        // apart.
        expectEqual(doc.lines.first?.words, nil, "standard LRC line has no words")

        // Never crash on garbage input.
        let garbage = LRCParser.parse("not lyrics at all\n[[[\n\n[99:99:99:99]???")
        expectEqual(garbage.lines.count, 0, "pure garbage parses to zero lines, not a crash")

        // Positive offset, and a 3-digit (millisecond) fractional part alongside a
        // 2-digit (centisecond) one in the same file.
        let mixedPrecision = LRCParser.parse("[offset:250]\n[00:01.5]Two-digit\n[00:02.500]Three-digit")
        expectClose(mixedPrecision.lines.first(where: { $0.text == "Two-digit" })?.start ?? -1, 1.75, 0.001,
                    "centisecond timestamp + positive offset")
        expectClose(mixedPrecision.lines.first(where: { $0.text == "Three-digit" })?.start ?? -1, 2.75, 0.001,
                    "millisecond timestamp + positive offset")
    }

    // MARK: - LyricsDocument derived queries

    private static func lyricsDocument() {
        print("lyrics document")

        let doc = LyricsDocument(title: nil, artist: nil, album: nil, lines: [
            LyricLine(start: 0, text: "a", words: nil),
            LyricLine(start: 5, text: "b", words: nil),
            LyricLine(start: 10, text: "c", words: nil),
        ])

        expectEqual(doc.activeIndex(at: -1), nil, "before the first line: no active line")
        expectEqual(doc.activeIndex(at: 0), 0, "exactly at a line's start is active")
        expectEqual(doc.activeIndex(at: 4.999), 0, "just before the next line: previous stays active")
        expectEqual(doc.activeIndex(at: 5), 1, "exactly at the next line's start switches")
        expectEqual(doc.activeIndex(at: 999), 2, "past the last line: last line stays active")

        expectEqual(doc.end(of: 0, trackDuration: 15), 5, "a line's end is the next line's start")
        expectEqual(doc.end(of: 2, trackDuration: 15), 15, "the last line's end is track duration")

        expectEqual(LyricsDocument.empty.activeIndex(at: 5), nil, "empty document has no active line")
    }

    // MARK: - Word-level fill

    private static func wordFill() {
        print("word fill")

        let line = LyricLine(start: 0, text: "Hi there", words: [
            LyricWord(start: 0, text: "Hi "),
            LyricWord(start: 1, text: "there"),
        ])
        guard let layout = WordFill.layout(for: line) else {
            expect(false, "layout(for:) returned nil for a valid enhanced line")
            return
        }
        expectEqual(layout.totalCharacters, 8, "\"Hi \" (3) + \"there\" (5) = 8 characters")

        expectEqual(WordFill.fillProgress(layout, position: -1, lineEnd: 2), 0, "before the first word: 0")
        expectEqual(WordFill.fillProgress(layout, position: 0, lineEnd: 2), 0, "at word 1's start: 0")
        expectClose(WordFill.fillProgress(layout, position: 0.5, lineEnd: 2), 1.5 / 8, 0.001,
                    "halfway through word 1 (duration 0..1) → half of its 3 characters")
        expectClose(WordFill.fillProgress(layout, position: 1, lineEnd: 2), 3.0 / 8, 0.001,
                    "at word 2's start: exactly word 1's character span")
        expectEqual(WordFill.fillProgress(layout, position: 2, lineEnd: 2), 1, "at the line's end: fully filled")
        expectEqual(WordFill.fillProgress(layout, position: 10, lineEnd: 2), 1, "past the line's end: still 1, not >1")

        let standardLine = LyricLine(start: 0, text: "no words here", words: nil)
        expect(WordFill.layout(for: standardLine) == nil, "standard LRC line has no fill layout")
    }

    // MARK: - LyricsStore matching

    private static func lyricsStoreMatching() {
        print("lyrics store matching")

        expectEqual(LyricsStore.idComponent("spotify:track:abc123"), "abc123",
                    "spotify:track:X → X")
        expectEqual(LyricsStore.idComponent("abc123"), "abc123", "no colon: passed through")

        expectEqual(LyricsStore.normalize("Bohemian Rhapsody (Remastered 2011)"),
                    LyricsStore.normalize("bohemian rhapsody"),
                    "trailing parenthetical suffix is dropped for matching")
        expectEqual(LyricsStore.normalize("Title (Remaster) [2011]"), LyricsStore.normalize("Title"),
                    "multiple trailing bracket groups are all dropped")
        expectEqual(LyricsStore.normalize("Café del Mar"), "cafe del mar", "diacritics stripped")
        expectEqual(LyricsStore.normalize("  Multiple   Spaces  "), "multiple spaces",
                    "whitespace collapsed and trimmed")

        // End-to-end priority matching against a real (temporary, disposable) directory —
        // never touches the user's actual ~/Music/Lyrics.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurntableSelfTestLyrics-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func write(_ name: String) {
            try? "[00:00.00]x".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        write("xyz789.lrc")               // priority 1: track id
        write("The Artist - The Title.lrc") // priority 2: artist - title
        write("The Title.lrc")             // priority 3: title alone

        let store = LyricsStore(additionalDirectory: tempDir)
        let track = Track(id: "spotify:track:xyz789", title: "The Title", artist: "The Artist",
                          album: "Album", duration: 200, artworkURL: nil)

        expectEqual(store.url(for: track)?.lastPathComponent, "xyz789.lrc",
                    "track-id match wins over artist-title and title matches")

        // Remove the id match — artist-title should win next.
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("xyz789.lrc"))
        let storeWithoutID = LyricsStore(additionalDirectory: tempDir)
        expectEqual(storeWithoutID.url(for: track)?.lastPathComponent, "The Artist - The Title.lrc",
                    "with no id match, artist-title wins over title alone")

        // Remove that too — title alone should win.
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("The Artist - The Title.lrc"))
        let storeTitleOnly = LyricsStore(additionalDirectory: tempDir)
        expectEqual(storeTitleOnly.url(for: track)?.lastPathComponent, "The Title.lrc",
                    "with neither id nor artist-title match, title alone matches")

        // A track with nothing on disk: no match, not a crash.
        let unmatched = Track(id: "spotify:track:nope", title: "Nothing Here", artist: "Nobody",
                              album: "", duration: 100, artworkURL: nil)
        expect(storeTitleOnly.url(for: unmatched) == nil, "no match found → nil, not an error")

        // Normalization applies to the on-disk filename too, not just the query side —
        // a "(Remastered)" suffix on the *file* must still match a plain-title track.
        write("Remastered Match (Live).lrc")
        let storeRemaster = LyricsStore(additionalDirectory: tempDir)
        let remasterTrack = Track(id: "spotify:track:zzz", title: "Remastered Match", artist: "X",
                                  album: "", duration: 100, artworkURL: nil)
        expectEqual(storeRemaster.url(for: remasterTrack)?.lastPathComponent, "Remastered Match (Live).lrc",
                    "normalization strips brackets from the filename side too")
    }

    // MARK: - LyricsFetcher request construction (no network — URL building only)

    private static func lyricsFetcherRequestURL() {
        print("lyrics fetcher request URL")

        let url = LyricsFetcher.requestURL(
            title: "No Heart", artist: "21 Savage", album: "Without Warning", duration: 154.6)
        expect(url != nil, "a plain title/artist builds a request URL")
        expectEqual(url?.host, "lrclib.net", "targets lrclib.net")
        expectEqual(url?.path, "/api/get", "targets the /api/get endpoint")

        let query = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        expectEqual(value("track_name"), "No Heart", "track_name passed through")
        expectEqual(value("artist_name"), "21 Savage", "artist_name passed through")
        expectEqual(value("album_name"), "Without Warning", "album_name passed through")
        // The API wants whole seconds; a fractional duration must round, not truncate.
        expectEqual(value("duration"), "155", "duration rounded to the nearest whole second")

        // A title with characters that need percent-encoding (spaces, "&") must still
        // produce a valid URL rather than nil.
        let encoded = LyricsFetcher.requestURL(
            title: "Rock & Roll (feat. Someone)", artist: "A & B", album: "", duration: 200)
        expect(encoded != nil, "special characters still produce a valid URL")
    }

    // MARK: - LyricsSyncSettings

    private static func lyricsSyncSettings() {
        print("lyrics sync settings")

        let defaults = Self.ephemeralDefaults()
        let settings = LyricsSyncSettings(defaults: defaults)
        expectEqual(settings.offset, 0, "starts at zero with nothing stored")

        settings.nudgeEarlier()
        expectClose(settings.offset, 0.25, 0.001, "one earlier-nudge is +0.25s")
        settings.nudgeEarlier()
        expectClose(settings.offset, 0.50, 0.001, "two earlier-nudges accumulate")
        settings.nudgeLater()
        expectClose(settings.offset, 0.25, 0.001, "a later-nudge cancels an earlier one")

        settings.reset()
        expectEqual(settings.offset, 0, "reset returns to zero")

        // Fat-fingering the same direction repeatedly must clamp, not run away —
        // otherwise a stuck key produces an offset nobody could explain from the UI.
        for _ in 0..<50 { settings.nudgeEarlier() }
        expectEqual(settings.offset, LyricsSyncSettings.range.upperBound, "nudging clamps at the upper bound")
        for _ in 0..<50 { settings.nudgeLater() }
        expectEqual(settings.offset, LyricsSyncSettings.range.lowerBound, "nudging clamps at the lower bound")

        // Persistence: a fresh instance over the same defaults picks up where the last
        // one left off, which is the entire point of storing it at all.
        settings.reset()
        settings.nudgeEarlier()
        let reloaded = LyricsSyncSettings(defaults: defaults)
        expectClose(reloaded.offset, 0.25, 0.001, "a new instance loads the persisted offset")

        // A value from a previous build outside today's clamp range (or simple
        // corruption) must not silently apply — fall back to zero instead of an offset
        // the UI never explained.
        defaults.set(999.0, forKey: "dev.kesgin.Turntable.lyricsSyncOffsetSeconds")
        let corrupted = LyricsSyncSettings(defaults: defaults)
        expectEqual(corrupted.offset, 0, "an out-of-range stored value is rejected, not clamped in")
    }

    // MARK: - OverlaySettings

    private static func overlaySettings() {
        print("overlay settings")

        let defaults = Self.ephemeralDefaults()
        let settings = OverlaySettings(defaults: defaults)
        expectEqual(settings.position, .center, "defaults to center with nothing stored")

        settings.set(.bottomTrailing)
        expectEqual(settings.position, .bottomTrailing, "set updates the published position")

        let reloaded = OverlaySettings(defaults: defaults)
        expectEqual(reloaded.position, .bottomTrailing, "a new instance loads the persisted position")

        // Every case must round-trip through its raw value — this is exactly what
        // persistence depends on, and a typo in a case name would silently reset
        // everyone to center on next launch.
        for position in OverlayPosition.allCases {
            expectEqual(OverlayPosition(rawValue: position.rawValue), position,
                        "\(position) round-trips through its raw value")
        }

        // An unrecognized stored value (e.g. a case removed in a later version) must
        // fall back to center rather than crash or leave `position` stale.
        defaults.set("diagonal", forKey: "dev.kesgin.Turntable.overlayPosition")
        let corrupted = OverlaySettings(defaults: defaults)
        expectEqual(corrupted.position, .center, "an unrecognized stored value falls back to center")
    }

    // MARK: - LyricsVisibilitySettings

    private static func lyricsVisibilitySettings() {
        print("lyrics visibility settings")

        let defaults = Self.ephemeralDefaults()
        let settings = LyricsVisibilitySettings(defaults: defaults)
        expectEqual(settings.isEnabled, true, "defaults to enabled with nothing stored")

        settings.toggle()
        expectEqual(settings.isEnabled, false, "toggle flips to disabled")

        let reloaded = LyricsVisibilitySettings(defaults: defaults)
        expectEqual(reloaded.isEnabled, false, "a new instance loads the persisted value")

        settings.toggle()
        expectEqual(settings.isEnabled, true, "toggling again flips back to enabled")
    }

    // MARK: - DisplaySettings

    private static func displaySettings() {
        print("display settings")

        let defaults = Self.ephemeralDefaults()
        let settings = DisplaySettings(defaults: defaults)
        expectEqual(settings.screenName, nil, "defaults to nil (follow main) with nothing stored")

        settings.set("DELL U2720Q")
        expectEqual(settings.screenName, "DELL U2720Q", "set updates the published name")

        let reloaded = DisplaySettings(defaults: defaults)
        expectEqual(reloaded.screenName, "DELL U2720Q", "a new instance loads the persisted name")

        settings.set(nil)
        expectEqual(settings.screenName, nil, "set(nil) clears back to \"follow main\"")
        expect(defaults.string(forKey: "dev.kesgin.Turntable.displayName") == nil,
               "set(nil) removes the stored key rather than storing an empty string")

        // Matching against a live screen exercises the actual comparison this app relies
        // on, without asserting anything about hardware this test doesn't control.
        if let liveScreen = NSScreen.screens.first {
            settings.set(liveScreen.localizedName)
            expectEqual(settings.resolveScreen(from: [liveScreen])?.localizedName, liveScreen.localizedName,
                        "a name matching a connected screen resolves to that screen")
        } else {
            print("  (skipped live-screen match: no screens reported)")
        }

        // A name that matches nothing currently connected (monitor unplugged) must not
        // strand the resolution — fall back to main rather than nil.
        settings.set("Some Monitor That Definitely Is Not Connected")
        expectEqual(settings.resolveScreen(from: NSScreen.screens)?.frame, NSScreen.main?.frame,
                    "an unmatched stored name falls back to the main screen")
    }

    /// A `UserDefaults` suite scoped to this test run only — never touches the real
    /// `dev.kesgin.Turntable` domain (`UserDefaults.standard`) the app actually persists
    /// to, and needs no cleanup since it's never written to disk under a stable name.
    private static func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SelfTest-\(UUID().uuidString)") ?? .standard
    }
}
