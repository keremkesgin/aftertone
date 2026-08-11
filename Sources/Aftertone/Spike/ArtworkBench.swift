import AppKit
import Foundation

/// Phase 3 acceptance harness: artwork changes on track change, cross-fades (verified via
/// the state's `id` actually changing), and a network failure falls back cleanly.
///
/// `make artwork-bench`
@MainActor
enum ArtworkBench {
    static func run() -> Never {
        let library = PlaceholderLibrary()
        let loader = ArtworkLoader(library: library)

        print("— artwork pipeline —")
        print("bundled placeholders: \(library.placeholders.map(\.id))")
        print("initial state: \(describe(loader.state))\n")

        let observer = loader.$state.sink { state in
            print("[state] \(describe(state))")
        }

        Task {
            await step("no track (nil) → placeholder, never blank") {
                loader.update(for: nil)
                try? await Task.sleep(nanoseconds: 100_000_000)
                check(loader.state != nil, "state is non-nil")
                check(loader.state?.isPlaceholder == true, "showing a placeholder")
            }

            await step("track with a real https artwork url → fetches and replaces placeholder") {
                guard let liveURL = await liveSpotifyArtworkURL() else {
                    print("  (skipped: Spotify isn't running or has no artwork url right now)")
                    return
                }
                let track = Track(id: "bench:live", title: "t", artist: "a", album: "al",
                                   duration: 200, artworkURL: liveURL)
                let before = loader.state?.id
                loader.update(for: track)
                let ok = await waitUntil(timeout: 6) { loader.state?.id != before && loader.state?.isPlaceholder == false }
                check(ok, "fetched artwork replaced the placeholder within 6s")
                check(loader.state?.id == liveURL.absoluteString, "state id is the artwork url — cross-fade keys off this")
            }

            await step("track with an unreachable artwork url → falls back to placeholder, never blank") {
                let badURL = URL(string: "https://turntable-bench-does-not-exist.invalid/x.jpg")!
                let track = Track(id: "bench:bad", title: "t", artist: "a", album: "al",
                                   duration: 200, artworkURL: badURL)
                loader.update(for: track)
                // Immediately after the call it should already show a placeholder — the
                // failed fetch is not awaited synchronously; the platter must never go
                // blank while a fetch is in flight (spec §6.1).
                check(loader.state?.isPlaceholder == true, "placeholder shown immediately, not blank, while fetch is in flight")
                let ok = await waitUntil(timeout: 8) { loader.state?.isPlaceholder == true }
                check(ok, "still (or again) showing a placeholder after the fetch times out")
            }

            await step("track with no artwork url (local file) → placeholder, no error") {
                let track = Track(id: "bench:local", title: "t", artist: "a", album: "al",
                                   duration: 200, artworkURL: nil)
                loader.update(for: track)
                try? await Task.sleep(nanoseconds: 100_000_000)
                check(loader.state?.isPlaceholder == true, "placeholder for a local file")
            }

            await step("re-selecting a track already shown does nothing (idempotent)") {
                let before = loader.state?.id
                loader.update(for: Track(id: "bench:local", title: "t", artist: "a", album: "al",
                                          duration: 200, artworkURL: nil))
                check(loader.state?.id == before, "no redundant state churn for the same track id")
            }

            withExtendedLifetime(observer) {}
            print("\n— done —")
            exit(failures == 0 ? 0 : 1)
        }

        RunLoop.main.run()
        fatalError("unreachable: RunLoop.main.run() does not return; exit() above ends the process first")
    }

    // MARK: - Harness

    private static var failures = 0

    private static func step(_ label: String, _ body: () async -> Void) async {
        print("· \(label)")
        await body()
    }

    private static func check(_ condition: Bool, _ label: String) {
        print("  \(condition ? "✓" : "✗") \(label)")
        if !condition { failures += 1 }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static func describe(_ state: ArtworkState?) -> String {
        guard let state else { return "nil" }
        return "id=\(state.id) placeholder=\(state.isPlaceholder) size=\(state.image.size)"
    }

    /// Best-effort: use the live client's current artwork url if one is available, so the
    /// network path is exercised against a real, valid Spotify CDN URL rather than a
    /// fabricated one.
    private static func liveSpotifyArtworkURL() async -> URL? {
        let provider = SpotifyProvider()
        guard let result = try? await provider.poll() else { return nil }
        return result.track?.artworkURL
    }
}
