import AppKit
import SwiftUI

/// A full-screen diagonal gradient built from the current album artwork's palette — a
/// synthetic "wallpaper" that fills the desktop window behind the badge/vinyl content.
///
/// Not a literal use of the palette bands: averaged band colors are muddy, and stacking
/// them as-is reads as stripes, not a wallpaper. Instead the most vivid band anchors the
/// gradient, and the dark and light ends are *derived* from it in HSB — near-black at the
/// top-leading corner, the vivid color through the middle, a pale tint at the
/// bottom-trailing corner — which is what gives every cover the same dark-to-light sweep
/// regardless of how washed-out its raw band averages come back.
struct GradientWallpaperView: View {
    let palette: ArtworkPalette

    var body: some View {
        // Near-vertical with only a slight lean, not corner-to-corner: a true diagonal
        // puts the ramp's bright middle onto the top-trailing corner, which reads as a
        // white wash along the top edge. Keeping the axis mostly vertical means the
        // entire top edge sits in the dark end, menu bar included.
        LinearGradient(
            stops: Self.stops(for: palette),
            startPoint: UnitPoint(x: 0.3, y: 0),
            endPoint: UnitPoint(x: 0.7, y: 1))
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 1.2), value: palette)
    }

    static func stops(for palette: ArtworkPalette) -> [Gradient.Stop] {
        let anchor = vividAnchor(in: palette)
        // The vivid stop sits past the midpoint so the dark end owns more area — matches
        // how these gradients are usually composed, and keeps light desktop icons/labels
        // readable over the upper half.
        // The light end stays clearly *colored*, not white: it keeps over half the
        // anchor's saturation and tops out well under full brightness. Pushing it any
        // paler reads as a white wash spilling into the corners rather than a tint of
        // the album color.
        //
        // Band averaging desaturates — a red cover with white text averages to pink —
        // so a cover with *any* real chroma gets its saturation floored back up rather
        // than trusted as-is. Truly gray covers (chroma below the floor's gate) skip
        // this and stay gray; inventing color there would be a lie.
        let hasChroma = anchor.s > 0.15
        return [
            .init(color: derive(anchor, saturation: min(1, anchor.s * 1.1), brightness: 0.10),
                  location: 0.0),
            .init(color: derive(anchor,
                                saturation: hasChroma ? max(min(1, anchor.s * 1.2 + 0.05), 0.65) : anchor.s,
                                brightness: min(max(anchor.b, 0.7), 0.8)),
                  location: 0.65),
            .init(color: derive(anchor,
                                saturation: hasChroma ? max(anchor.s * 0.6, 0.35) : anchor.s * 0.6,
                                brightness: 0.85),
                  location: 1.0),
        ]
    }

    private struct HSB { var h: CGFloat; var s: CGFloat; var b: CGFloat }

    /// The band whose color carries the most chroma (saturation × brightness) — the one
    /// a person would name if asked "what color is this cover?". A grayscale cover has
    /// no such band; whatever wins still produces a sensible gray gradient because the
    /// derivation only scales its (near-zero) saturation.
    private static func vividAnchor(in palette: ArtworkPalette) -> HSB {
        let candidates = palette.colors.map { hsb(of: $0) }
        guard let best = candidates.max(by: { $0.s * $0.b < $1.s * $1.b }) else {
            return HSB(h: 0, s: 0, b: 0.5)
        }
        return best
    }

    private static func hsb(of color: Color) -> HSB {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return HSB(h: 0, s: 0, b: 0.5)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return HSB(h: h, s: s, b: b)
    }

    private static func derive(_ anchor: HSB, saturation: CGFloat, brightness: CGFloat) -> Color {
        Color(nsColor: NSColor(
            hue: anchor.h,
            saturation: min(max(saturation, 0), 1),
            brightness: min(max(brightness, 0), 1),
            alpha: 1))
    }
}
