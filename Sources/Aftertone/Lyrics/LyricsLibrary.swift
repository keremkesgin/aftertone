import Foundation

/// Resolves and parses the `.lrc` for the current track: a local file first, then a
/// network fetch from lrclib.net when nothing local matches. No lyrics found (local or
/// remote) is not an error — `document` simply goes `nil` and the view hides silently.
@MainActor
final class LyricsLibrary: ObservableObject {
    @Published private(set) var document: LyricsDocument?

    private let store: LyricsStore
    private let fetcher: LyricsFetcher
    private var loadedTrackID: String?
    private var currentTrack: Track?
    /// Bumped on every `update(for:)`; a fetch that lands after the track has since
    /// changed again checks this before touching `document`, so a slow response for a
    /// skipped track can't overwrite what's playing now.
    private var generation = 0
    /// Once a track has failed a network fetch, it's not retried again for the rest of
    /// this run — a mismatched title/artist/duration will keep 404ing, so retrying on
    /// every folder-watch tick or replay would just be repeated failed requests. Clears
    /// naturally on the next app launch.
    private var failedFetchTrackIDs: Set<String> = []

    init(store: LyricsStore, fetcher: LyricsFetcher = LyricsFetcher()) {
        self.store = store
        self.fetcher = fetcher
        store.startWatching { [weak self] in self?.reloadCurrent() }
    }

    func update(for track: Track?) {
        currentTrack = track
        generation += 1
        guard let track else {
            loadedTrackID = nil
            document = nil
            return
        }
        guard track.id != loadedTrackID else { return }
        loadedTrackID = track.id
        load(track)
    }

    /// The watched folder changed (a file was added/edited/removed) — re-resolve the
    /// *current* track against the fresh index rather than waiting for the next track
    /// change, so dropping a `.lrc` in while a song is already playing works immediately.
    private func reloadCurrent() {
        guard let track = currentTrack else { return }
        load(track)
    }

    private func load(_ track: Track) {
        if let url = store.url(for: track), let text = Self.readText(url) {
            document = LRCParser.parse(text)
            return
        }

        document = nil
        guard !failedFetchTrackIDs.contains(track.id) else { return }

        let requestGeneration = generation
        Task { [weak self, fetcher] in
            guard let text = await fetcher.fetchSyncedLyrics(
                title: track.title, artist: track.artist, album: track.album, duration: track.duration
            ) else {
                self?.failedFetchTrackIDs.insert(track.id)
                return
            }
            guard let self, requestGeneration == self.generation else { return }
            Self.cache(text, for: track)
            self.document = LRCParser.parse(text)
        }
    }

    /// Writes a fetched lyric to `~/Music/Lyrics/<id>.lrc` so it's found locally (and
    /// offline) on every future play — same directory and naming `LyricsStore` already
    /// indexes, so no separate cache lookup path is needed.
    private static func cache(_ text: String, for track: Track) {
        guard let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        else { return }
        let directory = musicDirectory.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(LyricsStore.idComponent(track.id) + ".lrc")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// LRC files are nominally UTF-8 but old rips in the wild sometimes aren't — fall
    /// back rather than silently showing no lyrics for a file that does exist.
    private static func readText(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        return nil
    }
}
