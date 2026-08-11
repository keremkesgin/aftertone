import AppKit
import SwiftUI

/// Writes images to the real macOS desktop wallpaper.
///
/// `setDesktopImageURL` is a no-op when called with the URL that's *already* set for a
/// screen — the file's bytes can have changed underneath it, but macOS compares the URL,
/// not the content, and skips the redraw. Overwriting a single stable filename in place
/// therefore only ever updates the wallpaper once (the first call, whose URL differs from
/// whatever the user had before) and silently does nothing on every track after that. The
/// fix is to alternate between two stable filenames, so every call's URL genuinely differs
/// from whatever is currently set.
///
/// Used by gradient wallpaper mode for one reason the in-window gradient can't cover: the
/// menu bar's legibility scrim is derived from the wallpaper *file* macOS has on record,
/// not from what's visually behind the menu bar — so a pale real wallpaper bleeds a white
/// band across the top of an otherwise dark overlay. Setting the real wallpaper to the
/// same gradient is what makes the scrim inherit the dark top.
@MainActor
final class WallpaperSetter {
    private let primaryURL: URL
    private let secondaryURL: URL
    private var usingSecondary = false
    private var lastAppliedID: String?

    private let defaults: UserDefaults
    /// The user's own wallpaper per screen (keyed by `localizedName`), captured before
    /// the first gradient overwrites it. Persisted so a relaunch can still restore it.
    private static let originalsKey = "dev.kesgin.Turntable.originalWallpapers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Turntable")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        primaryURL = directory.appendingPathComponent("wallpaper-a.jpg")
        secondaryURL = directory.appendingPathComponent("wallpaper-b.jpg")
    }

    // MARK: - Gradient wallpaper

    /// Renders the palette's gradient and sets it as the real wallpaper on every screen.
    /// No-op when `id` (the artwork identity) is already applied.
    func applyGradient(palette: ArtworkPalette, id: String) {
        guard id != lastAppliedID else { return }
        saveOriginalsIfNeeded()

        guard let screen = NSScreen.screens.first else { return }
        let image = Self.gradientImage(
            stops: GradientWallpaperView.stops(for: palette), size: screen.frame.size)
        apply(image, id: id)
    }

    /// Puts back whatever wallpaper each screen had before the first gradient was
    /// applied, then forgets it. Safe to call repeatedly — a no-op with nothing stored.
    func restoreOriginals() {
        guard let stored = defaults.dictionary(forKey: Self.originalsKey) as? [String: String] else {
            return
        }
        for screen in NSScreen.screens {
            guard let string = stored[screen.localizedName], let url = URL(string: string) else {
                continue
            }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        defaults.removeObject(forKey: Self.originalsKey)
        lastAppliedID = nil
    }

    /// Captures the current per-screen wallpaper, once. Skips our own alternating files:
    /// after a crash or force-quit that never restored, the "current wallpaper" *is* a
    /// stale gradient, and recording that as the user's original would make restore
    /// meaningless forever after.
    private func saveOriginalsIfNeeded() {
        guard defaults.object(forKey: Self.originalsKey) == nil else { return }
        var originals: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  url != primaryURL, url != secondaryURL
            else { continue }
            originals[screen.localizedName] = url.absoluteString
        }
        guard !originals.isEmpty else { return }
        defaults.set(originals, forKey: Self.originalsKey)
    }

    /// AppKit's y axis points up, SwiftUI's down — the view's top-leading start point
    /// `(0.3, 0)` is `(0.3·w, h)` here. Same near-vertical axis, same stops.
    private static func gradientImage(stops: [Gradient.Stop], size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let colors = stops.map { NSColor($0.color).usingColorSpace(.sRGB) ?? .black }
        let locations = stops.map { CGFloat($0.location) }
        if let gradient = NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB) {
            gradient.draw(
                from: NSPoint(x: 0.3 * size.width, y: size.height),
                to: NSPoint(x: 0.7 * size.width, y: 0),
                options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Shared plumbing

    private func apply(_ image: NSImage, id: String) {
        guard let data = Self.jpegData(image) else {
            NSLog("[Aftertone] Could not encode image for wallpaper.")
            return
        }

        let targetURL = usingSecondary ? primaryURL : secondaryURL
        do {
            try data.write(to: targetURL, options: .atomic)
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(targetURL, for: screen, options: [:])
            }
            usingSecondary.toggle()
            lastAppliedID = id
        } catch {
            NSLog("[Aftertone] Failed to set wallpaper: %@", error.localizedDescription)
        }
    }

    private static func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
