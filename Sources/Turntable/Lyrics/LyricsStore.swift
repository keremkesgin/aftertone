import Foundation

/// Locates the `.lrc` file for a track by scanning `~/Music/Lyrics/` plus an optional
/// user-configured folder, matching in priority order (spec §8.2):
///
/// 1. `<spotify-track-id>.lrc`
/// 2. `<artist> - <title>.lrc`
/// 3. `<title>.lrc`
///
/// Builds the index once at launch and refreshes it on a filesystem watch of the
/// directories — no per-poll directory scanning.
final class LyricsStore {
    private(set) var searchDirectories: [URL]
    /// Normalized filename stem → file URL. Rebuilt wholesale on any change; libraries
    /// this small (hundreds of `.lrc` files, at most) don't need incremental updates.
    private var index: [String: URL] = [:]
    private var watchSources: [DispatchSourceFileSystemObject] = []
    private var onIndexChanged: (() -> Void)?

    init(additionalDirectory: URL? = nil) {
        var directories: [URL] = []
        if let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first {
            directories.append(musicDirectory.appendingPathComponent("Lyrics", isDirectory: true))
        }
        if let additionalDirectory {
            directories.append(additionalDirectory)
        }
        self.searchDirectories = directories
        rebuildIndex()
    }

    deinit {
        for source in watchSources { source.cancel() }
    }

    /// Call once, after `init`, to start watching. Kept separate from `init` so tests can
    /// construct a store without touching `DispatchSource`/kqueue at all.
    func startWatching(onChange: (() -> Void)? = nil) {
        onIndexChanged = onChange
        watchSources.forEach { $0.cancel() }
        watchSources = searchDirectories.compactMap(makeWatch)
    }

    /// Swap in a different user-configured folder (Phase 6's Settings will call this;
    /// for now it's exercised directly by tests and any future caller).
    func setAdditionalDirectory(_ url: URL?) {
        var directories: [URL] = []
        if let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first {
            directories.append(musicDirectory.appendingPathComponent("Lyrics", isDirectory: true))
        }
        if let url { directories.append(url) }
        searchDirectories = directories
        rebuildIndex()
        let hadWatchers = !watchSources.isEmpty
        watchSources.forEach { $0.cancel() }
        watchSources = hadWatchers ? searchDirectories.compactMap(makeWatch) : []
    }

    // MARK: - Lookup

    func url(for track: Track) -> URL? {
        if let byID = index[Self.normalize(Self.idComponent(track.id))] { return byID }
        if let byArtistTitle = index[Self.normalize("\(track.artist) - \(track.title)")] { return byArtistTitle }
        if let byTitle = index[Self.normalize(track.title)] { return byTitle }
        return nil
    }

    // MARK: - Index

    private func rebuildIndex() {
        var newIndex: [String: URL] = [:]
        for directory in searchDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue } // directory absent/unreadable — not an error (spec §12)

            for file in files where file.pathExtension.lowercased() == "lrc" {
                let key = Self.normalize(file.deletingPathExtension().lastPathComponent)
                // Earlier directories in `searchDirectories` win — `~/Music/Lyrics/`
                // before the user-configured extra folder — rather than whichever the
                // filesystem happens to enumerate last.
                if newIndex[key] == nil { newIndex[key] = file }
            }
        }
        index = newIndex
    }

    private func makeWatch(_ directory: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil } // directory doesn't exist yet — acceptable

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.rebuildIndex()
            self?.onIndexChanged?()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    // MARK: - Matching (spec §8.2)

    /// `spotify:track:abc123` → `abc123`.
    static func idComponent(_ trackID: String) -> String {
        trackID.split(separator: ":").last.map(String.init) ?? trackID
    }

    /// Lowercase, strip diacritics, collapse whitespace, drop trailing
    /// parenthetical/bracket suffixes — "remaster and remix suffixes are the main cause
    /// of misses" (spec §8.2).
    static func normalize(_ raw: String) -> String {
        var value = stripTrailingBracketedSuffixes(raw)
        value = value.lowercased()
        value = value.folding(options: .diacriticInsensitive, locale: nil)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Strips *trailing* `(…)` / `[…]` groups, repeatedly — "Title (Remaster) [2011]"
    /// loses both, but a leading parenthetical (rare, but not what spec §8.2 asks to
    /// drop) is left alone.
    private static func stripTrailingBracketedSuffixes(_ raw: String) -> String {
        var value = raw
        while true {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.last, last == ")" || last == "]" else { return trimmed }
            let opening: Character = last == ")" ? "(" : "["
            guard let openIndex = trimmed.lastIndex(of: opening) else { return trimmed }
            value = String(trimmed[trimmed.startIndex..<openIndex])
        }
    }
}
