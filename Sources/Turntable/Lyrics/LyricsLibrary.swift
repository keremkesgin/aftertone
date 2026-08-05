import Foundation

/// Resolves and parses the `.lrc` for the current track. No `.lrc` found is not an error —
/// `document` simply goes `nil` and the panel hides silently (spec §12).
@MainActor
final class LyricsLibrary: ObservableObject {
    @Published private(set) var document: LyricsDocument?

    private let store: LyricsStore
    private var loadedTrackID: String?
    private var currentTrack: Track?

    init(store: LyricsStore) {
        self.store = store
        store.startWatching { [weak self] in self?.reloadCurrent() }
    }

    func update(for track: Track?) {
        currentTrack = track
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
        guard let url = store.url(for: track), let text = Self.readText(url) else {
            document = nil
            return
        }
        document = LRCParser.parse(text)
    }

    /// LRC files are nominally UTF-8 but old rips in the wild sometimes aren't — fall
    /// back rather than silently showing no lyrics for a file that does exist.
    private static func readText(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        return nil
    }
}
