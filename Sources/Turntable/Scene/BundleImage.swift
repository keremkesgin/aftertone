import SwiftUI

/// Resolves a scene asset from `Resources/Scene/<name>.png`.
///
/// Spec §7.2's own code sample writes `Image("vinyl-grooves")`, which on macOS resolves
/// through `NSImage(named:)` — but that only searches the *flat top level* of the app
/// bundle's `Resources/`, never subdirectories (confirmed empirically: a file at
/// `Contents/Resources/Scene/x.png` is invisible to it, while
/// `Bundle.main.url(forResource:subdirectory:)` finds it fine). Since spec §3 puts these
/// assets under `Resources/Scene/`, and we're not compiling an asset catalog (no Xcode on
/// this machine), this resolver takes over what `Image("name")` can't do here.
enum SceneAsset {
    private static var cache: [String: NSImage] = [:]

    /// Never returns nil — a missing asset gets a visible flat-color stand-in instead of
    /// a silent blank, the same "never blank" discipline as `ArtworkLoader` (spec §6.1).
    static func image(_ name: String) -> Image {
        Image(nsImage: resolve(name))
    }

    static func resolve(_ name: String) -> NSImage {
        if let cached = cache[name] { return cached }

        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Scene"),
              let image = NSImage(contentsOf: url)
        else {
            NSLog("[Turntable] Scene asset '%@' missing or undecodable — using a placeholder fill.", name)
            let placeholder = fallback()
            cache[name] = placeholder
            return placeholder
        }
        cache[name] = image
        return image
    }

    private static func fallback() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemPink.withAlphaComponent(0.4).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
