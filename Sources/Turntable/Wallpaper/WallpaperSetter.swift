import AppKit

/// Writes the current track's artwork to the real macOS desktop wallpaper.
///
/// `setDesktopImageURL` is a no-op when called with the URL that's *already* set for a
/// screen — the file's bytes can have changed underneath it, but macOS compares the URL,
/// not the content, and skips the redraw. Overwriting a single stable filename in place
/// therefore only ever updates the wallpaper once (the first call, whose URL differs from
/// whatever the user had before) and silently does nothing on every track after that. The
/// fix is to alternate between two stable filenames, so every call's URL genuinely differs
/// from whatever is currently set.
@MainActor
final class WallpaperSetter {
    private let primaryURL: URL
    private let secondaryURL: URL
    private var usingSecondary = false
    private var lastAppliedID: String?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Turntable")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        primaryURL = directory.appendingPathComponent("wallpaper-a.jpg")
        secondaryURL = directory.appendingPathComponent("wallpaper-b.jpg")
    }

    /// Call with every non-placeholder `ArtworkState`. No-op if this is already applied.
    func apply(_ state: ArtworkState) {
        guard state.id != lastAppliedID else { return }
        guard let data = Self.jpegData(state.image) else {
            NSLog("[Turntable] Could not encode artwork for wallpaper.")
            return
        }

        let targetURL = usingSecondary ? primaryURL : secondaryURL
        do {
            try data.write(to: targetURL, options: .atomic)
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(targetURL, for: screen, options: [:])
            }
            usingSecondary.toggle()
            lastAppliedID = state.id
        } catch {
            NSLog("[Turntable] Failed to set wallpaper: %@", error.localizedDescription)
        }
    }

    private static func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
