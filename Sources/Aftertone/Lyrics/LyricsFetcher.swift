import Foundation

/// Fetches synced lyrics from lrclib.net when `LyricsStore` has no local `.lrc` match.
/// Free, keyless, community-sourced — no account, no rate-limit key to manage. This is a
/// best-effort convenience, not a guarantee: a title/artist/duration mismatch (remixes,
/// "(Deluxe)" editions, wrong album tag) can miss even when lyrics exist for the track
/// under a slightly different metadata shape.
struct LyricsFetcher {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns LRC-formatted text, or `nil` on any failure (network, 404, no synced
    /// lyrics for this track) — never throws. The caller decides what "no lyrics" means.
    func fetchSyncedLyrics(title: String, artist: String, album: String, duration: TimeInterval) async -> String? {
        guard let url = Self.requestURL(title: title, artist: artist, album: album, duration: duration) else {
            return nil
        }
        var request = URLRequest(url: url)
        // lrclib.net asks integrations to identify themselves with a descriptive
        // User-Agent rather than an API key.
        request.setValue("Aftertone (macOS desktop lyrics overlay)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }

        return decoded.syncedLyrics
    }

    /// Exposed for testing the query construction without a network call.
    static func requestURL(title: String, artist: String, album: String, duration: TimeInterval) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            // The API matches duration with a small tolerance; it wants whole seconds.
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        return components?.url
    }

    private struct Response: Decodable {
        let syncedLyrics: String?
    }
}
