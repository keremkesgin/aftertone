import AppKit
import CryptoKit
import Foundation

/// What the scene should currently draw. Never absent — the platter is never blank
/// (spec §6.1).
struct ArtworkState: Equatable {
    let image: NSImage
    /// Identity of the *source*, so the view can tell a genuine change from a redraw and
    /// only cross-fade when it actually changed.
    let id: String
    let isPlaceholder: Bool
    /// Label accent from the placeholder manifest, when one applies.
    let labelTint: NSColor?
}

/// Resolves a `Track` to an image: memory cache → disk cache → network → placeholder
/// (spec §6.1).
@MainActor
final class ArtworkLoader: ObservableObject {
    @Published private(set) var state: ArtworkState?

    private let library: PlaceholderLibrary
    private let session: URLSession

    /// Spec caps this at 40 entries. Artwork is ~600×600, so this is a few MB.
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    /// Rising token that invalidates in-flight fetches when the track changes again
    /// before the previous one finished.
    private var generation = 0
    /// Track id currently represented by `state`, to avoid redundant work on every poll.
    private var loadedTrackID: String?
    /// URLs that already failed. Spec §12: retry once on the *next* track change, so a
    /// failure is not re-attempted every poll for the same track.
    private var failedURLs: Set<URL> = []

    /// Placeholder the user picked in the menu. Also the fallback for every failure path.
    var selectedPlaceholderID: String? {
        didSet {
            guard selectedPlaceholderID != oldValue else { return }
            // If a placeholder is what's on screen, swap it immediately.
            if state?.isPlaceholder ?? true { showPlaceholder() }
        }
    }

    init(library: PlaceholderLibrary) {
        self.library = library

        let configuration = URLSessionConfiguration.ephemeral
        // 6s: long enough for a slow network, short enough that the placeholder appears
        // before the user wonders whether the app is broken.
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        // We do our own two-tier cache; the URL cache would just duplicate it.
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)

        showPlaceholder()
        Self.pruneDiskCache()
    }

    // MARK: - Entry point

    /// Call on every poll; cheap and idempotent when nothing changed.
    func update(for track: Track?) {
        guard let track else {
            if loadedTrackID != nil || state == nil {
                loadedTrackID = nil
                showPlaceholder()
            }
            return
        }

        guard track.id != loadedTrackID else { return }
        loadedTrackID = track.id
        generation += 1
        let token = generation

        // A new track is a new chance for a URL that failed before (spec §12).
        failedURLs.removeAll()

        guard let url = track.artworkURL else {
            // Local files and some ads have no artwork url. Not an error (spec §12).
            showPlaceholder()
            return
        }

        if let cached = memoryCache.object(forKey: url.absoluteString as NSString) {
            show(cached, id: url.absoluteString)
            return
        }

        // Show the placeholder while fetching rather than holding the previous track's
        // artwork, which would be wrong for however long the network takes.
        showPlaceholder()
        fetch(url, token: token)
    }

    // MARK: - Loading

    private func fetch(_ url: URL, token: Int) {
        let key = Self.digest(url.absoluteString)

        Task { [weak self] in
            // Disk first: survives relaunches, and re-fetching artwork we already have is
            // pure waste on a metered connection.
            if let image = await Self.loadFromDisk(key: key) {
                self?.adopt(image, url: url, token: token, writeToDisk: nil)
                return
            }

            guard let self else { return }
            do {
                let (data, response) = try await self.session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    self.recordFailure(url, token: token,
                                       reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return
                }
                guard let image = NSImage(data: data), image.size.width > 0 else {
                    self.recordFailure(url, token: token, reason: "undecodable image data")
                    return
                }
                self.adopt(image, url: url, token: token, writeToDisk: data)
            } catch {
                self.recordFailure(url, token: token, reason: error.localizedDescription)
            }
        }
    }

    private func adopt(_ image: NSImage, url: URL, token: Int, writeToDisk data: Data?) {
        // Cache even if stale: the user may come back to this track.
        memoryCache.setObject(image, forKey: url.absoluteString as NSString)
        if let data {
            let key = Self.digest(url.absoluteString)
            Task.detached(priority: .utility) { Self.writeToDisk(data, key: key) }
        }
        // Stale fetch — the track changed while this was in flight.
        guard token == generation else { return }
        show(image, id: url.absoluteString)
    }

    private func recordFailure(_ url: URL, token: Int, reason: String) {
        NSLog("[Turntable] Artwork fetch failed for %@: %@", url.absoluteString, reason)
        failedURLs.insert(url)
        guard token == generation else { return }
        showPlaceholder()
    }

    // MARK: - Publishing

    private func show(_ image: NSImage, id: String) {
        guard state?.id != id else { return }
        state = ArtworkState(image: image, id: id, isPlaceholder: false, labelTint: nil)
    }

    private func showPlaceholder() {
        guard let placeholder = library.resolve(id: selectedPlaceholderID) else {
            // No bundled artwork at all — only reachable in a broken build, but the
            // platter still must not be blank.
            guard state == nil else { return }
            state = ArtworkState(image: Self.fallbackImage(), id: "fallback",
                                 isPlaceholder: true, labelTint: nil)
            return
        }
        guard state?.id != placeholder.id else { return }
        guard let image = NSImage(contentsOf: placeholder.url) else {
            NSLog("[Turntable] Placeholder '%@' could not be decoded.", placeholder.id)
            return
        }
        state = ArtworkState(image: image, id: placeholder.id,
                             isPlaceholder: true, labelTint: placeholder.labelTint)
    }

    /// Last-resort flat fill. Never expected to be seen; exists so no code path can
    /// produce a nil image.
    private static func fallbackImage() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.14, green: 0.13, blue: 0.15, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - Disk cache
    //
    // All `nonisolated`: file I/O has no business on the main thread, and these are called
    // from detached tasks.

    private nonisolated static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `~/Library/Caches/<bundle-id>/artwork/`
    private nonisolated static var diskCacheDirectory: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appendingPathComponent(bundleID).appendingPathComponent("artwork")
    }

    private nonisolated static func diskURL(key: String) -> URL? {
        diskCacheDirectory?.appendingPathComponent("\(key).jpg")
    }

    private nonisolated static func loadFromDisk(key: String) async -> NSImage? {
        guard let url = diskURL(key: key) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }.value
    }

    private nonisolated static func writeToDisk(_ data: Data, key: String) {
        guard let directory = diskCacheDirectory, let url = diskURL(key: key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Keep the cache bounded. It lives in `Caches` so the system may purge it, but an
    /// app that runs for months shouldn't quietly accumulate every cover ever played.
    private nonisolated static func pruneDiskCache(limit: Int = 600) {
        Task.detached(priority: .background) {
            guard let directory = diskCacheDirectory,
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentAccessDateKey],
                    options: [.skipsHiddenFiles]),
                  entries.count > limit
            else { return }

            let byAge = entries.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentAccessDateKey]))?
                    .contentAccessDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentAccessDateKey]))?
                    .contentAccessDate ?? .distantPast
                return lhsDate < rhsDate
            }
            for url in byAge.prefix(entries.count - limit) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
