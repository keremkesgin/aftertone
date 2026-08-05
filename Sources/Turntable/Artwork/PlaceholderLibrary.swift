import AppKit
import Foundation

/// A selectable artwork that isn't coming from Spotify.
struct Placeholder: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    /// Optional accent used to tint the record label, parsed from `labelTint` in the
    /// manifest. `nil` for user-dropped files, which have no manifest entry.
    let labelTint: NSColor?

    /// User-added files sort after bundled ones and are labelled in the menu.
    let isUserProvided: Bool
}

/// Loads bundled placeholder artwork plus anything the user has dropped into Application
/// Support (spec §6.2).
///
/// Loose files with a JSON manifest rather than an asset catalog, so artwork can be added
/// without a rebuild.
final class PlaceholderLibrary {
    private(set) var placeholders: [Placeholder] = []

    /// `~/Library/Application Support/<bundle-id>/Placeholders/`
    static var userDirectory: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent(bundleID).appendingPathComponent("Placeholders")
    }

    init() {
        reload()
    }

    func reload() {
        placeholders = loadBundled() + loadUserProvided()
    }

    func placeholder(id: String) -> Placeholder? {
        placeholders.first { $0.id == id }
    }

    /// Falls back to the first available artwork so the platter is never blank (spec §6.1).
    func resolve(id: String?) -> Placeholder? {
        if let id, let match = placeholder(id: id) { return match }
        return placeholders.first
    }

    // MARK: - Bundled

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let file: String
            let labelTint: String?
        }
        let version: Int
        let artworks: [Entry]
    }

    private func loadBundled() -> [Placeholder] {
        guard let directory = Bundle.main.resourceURL?
            .appendingPathComponent("Placeholders", isDirectory: true) else { return [] }
        let manifestURL = directory.appendingPathComponent("manifest.json")

        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            NSLog("[Turntable] Placeholders/manifest.json is malformed; ignoring it.")
            return []
        }
        guard manifest.version == 1 else {
            NSLog("[Turntable] Placeholder manifest version %d is newer than this build understands.",
                  manifest.version)
            return []
        }

        // A manifest entry naming a missing file is dropped rather than surfaced as a
        // broken menu item.
        return manifest.artworks.compactMap { entry in
            let url = directory.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                NSLog("[Turntable] Placeholder '%@' names a missing file: %@", entry.id, entry.file)
                return nil
            }
            return Placeholder(
                id: entry.id,
                name: entry.name,
                url: url,
                labelTint: entry.labelTint.flatMap(NSColor.init(hexString:)),
                isUserProvided: false
            )
        }
    }

    // MARK: - User-provided

    private static let acceptedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    private func loadUserProvided() -> [Placeholder] {
        guard let directory = Self.userDirectory else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                Placeholder(
                    // Namespaced so a user file can never collide with a bundled id.
                    id: "user:\(url.lastPathComponent)",
                    name: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    labelTint: nil,
                    isUserProvided: true
                )
            }
    }

    /// Create the drop folder so the Settings "Reveal in Finder" button has somewhere to go.
    @discardableResult
    func ensureUserDirectoryExists() -> URL? {
        guard let directory = Self.userDirectory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

extension NSColor {
    /// Parses `#RRGGBB` / `#RRGGBBAA` as used by `labelTint` in the manifest.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }

        let hasAlpha = hex.count == 8
        let shift = hasAlpha ? 8 : 0
        let red = CGFloat((value >> (16 + shift)) & 0xFF) / 255
        let green = CGFloat((value >> (8 + shift)) & 0xFF) / 255
        let blue = CGFloat((value >> shift) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1

        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
