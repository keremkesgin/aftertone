import Foundation

/// Phase 7 acceptance harness: given the *live* current Spotify track, write a synthetic
/// `.lrc` for it into a scratch directory (never touches the user's real
/// `~/Music/Lyrics/`), confirm the store matches it, the parser produces a sane document,
/// and the active-line index tracks a simulated playback position correctly.
///
/// `make lyrics-bench`
@MainActor
enum LyricsBench {
    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let box = FailureCount()
        // `.detached`, and `runAsync` below is `nonisolated`: this function blocks the
        // main thread on `semaphore.wait()`, so nothing it awaits may need to hop back to
        // the main actor to proceed — same deadlock class fixed in `PollBench.run()`.
        Task.detached {
            await runAsync(failures: box)
            semaphore.signal()
        }
        semaphore.wait()
        exit(box.count == 0 ? 0 : 1)
    }

    private nonisolated static func runAsync(failures: FailureCount) async {
        func check(_ condition: Bool, _ label: String) {
            print("  \(condition ? "✓" : "✗") \(label)")
            if !condition { failures.increment() }
        }

        print("— lyrics pipeline —")

        let provider = SpotifyProvider()
        guard let snapshot = try? await provider.poll(), let track = snapshot.track else {
            print("  (skipped: Spotify isn't running or nothing is playing right now)")
            return
        }
        print("live track: \(track.title) — \(track.artist)  [\(track.album)]  id:\(track.id)")

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurntableLyricsBench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        // A synthetic file built from the *real* title/artist, so normalization is
        // exercised against real-world punctuation/casing/unicode rather than a fixture
        // I made convenient.
        let lrcText = """
        [ti:\(track.title)]
        [ar:\(track.artist)]
        [al:\(track.album)]
        [00:00.00]first line
        [00:03.00]<00:03.00>Second <00:03.50>line <00:04.00>word by word
        [00:06.00]third line
        """
        let fileName = "\(LyricsStore.idComponent(track.id)).lrc"
        let fileURL = scratchDir.appendingPathComponent(fileName)
        try? lrcText.write(to: fileURL, atomically: true, encoding: .utf8)
        print("wrote \(fileURL.lastPathComponent) into a scratch dir (not ~/Music/Lyrics)")

        let store = LyricsStore(additionalDirectory: scratchDir)
        let matched = store.url(for: track)
        check(matched?.lastPathComponent == fileName, "store matches the synthetic file by track id")

        guard let matched, let text = try? String(contentsOf: matched, encoding: .utf8) else {
            check(false, "could not read back the file we just wrote")
            return
        }
        let document = LRCParser.parse(text)
        check(document.title == track.title, "[ti:] round-trips the real title")
        check(document.artist == track.artist, "[ar:] round-trips the real artist")
        check(document.lines.count == 3, "three lines parsed")

        check(document.activeIndex(at: -1) == nil, "before line 1: no active line")
        check(document.activeIndex(at: 1) == 0, "t=1s: line 1 active")
        check(document.activeIndex(at: 3.2) == 1, "t=3.2s: line 2 (enhanced) active")
        check(document.activeIndex(at: 6.5) == 2, "t=6.5s: line 3 active")

        if let layout = document.lines.indices.contains(1) ? WordFill.layout(for: document.lines[1]) : nil {
            let end = document.end(of: 1, trackDuration: track.duration)
            let early = WordFill.fillProgress(layout, position: 3.0, lineEnd: end)
            let late = WordFill.fillProgress(layout, position: 3.9, lineEnd: end)
            check(early < late, "word-fill progress increases over time within the enhanced line"
                + " (t=3.0 → \(early), t=3.9 → \(late))")
        } else {
            check(false, "expected line 2 to have a word-fill layout")
        }

        // The library end to end: update(for:) should load exactly this document given
        // the live track, using the real matching path, not a stub. `LyricsLibrary` is
        // `@MainActor`; this function is nonisolated, so each call hops.
        let library = await LyricsLibrary(store: store)
        await library.update(for: track)
        let loadedCount = await library.document?.lines.count
        check(loadedCount == 3, "LyricsLibrary resolves the real track end-to-end")

        // And silently goes nil for a track nothing matches — no error (spec §12).
        let unmatched = Track(id: "spotify:track:nomatch-\(UUID().uuidString)", title: "Nothing Matches This",
                              artist: "Nobody", album: "", duration: 100, artworkURL: nil)
        await library.update(for: unmatched)
        let afterUnmatched = await library.document
        check(afterUnmatched == nil, "no match → document is nil, silently (panel hides itself)")

        print("\n— done —")
    }
}

/// A lock-protected counter shared between the detached benchmark task and `run()`'s main
/// thread — the same shape as `PollBench`'s `ManagedAtomicBox`, just counting instead of
/// flagging. `nonisolated(unsafe)` on a plain `static var` would also work on a newer
/// language mode; this is the version that's correct regardless of mode.
private final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
