import SwiftUI

/// A static, heavily blurred glow of color sampled from the current album artwork, pinned
/// to the four screen corners — an ambient "theme" that echoes the cover without showing
/// a literal picture. Static by design, unlike the ocean-wave experiment this replaced:
/// nothing here drives a per-frame redraw, so the (real, measured) cost of a continuous
/// blur never applies — this repaints once per track change and otherwise costs nothing.
struct AlbumGlowView: View {
    let palette: ArtworkPalette
    /// Multiplier on blob diameter, from `AlbumGlowSettings.sizeScale`.
    var sizeScale: Double = 1.0

    private static let blurRadius: CGFloat = 100
    private static let blobFraction: CGFloat = 0.6

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                blob(color(0), at: CGPoint(x: 0, y: 0), size: geometry.size)
                blob(color(1), at: CGPoint(x: geometry.size.width, y: 0), size: geometry.size)
                blob(color(2), at: CGPoint(x: geometry.size.width, y: geometry.size.height), size: geometry.size)
                blob(color(3), at: CGPoint(x: 0, y: geometry.size.height), size: geometry.size)
            }
        }
        .blur(radius: Self.blurRadius)
        .opacity(0.6)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.0), value: palette)
        .animation(.easeInOut(duration: 0.25), value: sizeScale)
    }

    private func color(_ index: Int) -> Color {
        guard !palette.colors.isEmpty else { return .clear }
        return palette.colors[index % palette.colors.count]
    }

    private func blob(_ color: Color, at point: CGPoint, size: CGSize) -> some View {
        let diameter = max(size.width, size.height) * Self.blobFraction * sizeScale
        return Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .position(point)
    }
}
