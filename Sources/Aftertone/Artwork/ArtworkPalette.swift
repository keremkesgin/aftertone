import AppKit
import SwiftUI

/// A handful of colors sampled from album artwork, used to tint the edge glow. This is
/// deliberately crude — four horizontal bands averaged, not real dominant-color
/// clustering — because the glow is heavily blurred on screen anyway; precision beyond a
/// few representative pixels buys nothing perceptible, and staying this simple keeps
/// extraction cheap enough to run synchronously on the main thread once per track change.
struct ArtworkPalette: Equatable {
    let colors: [Color]

    static let placeholder = ArtworkPalette(colors: [Color.white.opacity(0.15)])

    static func extract(from image: NSImage, bands: Int = 4) -> ArtworkPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .placeholder
        }

        // Downscale drastically before sampling — this is the whole cost-control trick.
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .placeholder }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return .placeholder }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // Split the downscaled image into horizontal bands (top of the cover vs. bottom,
        // roughly) and average each — a cheap stand-in for a real dominant-color palette.
        let rowsPerBand = max(1, side / bands)
        var colors: [Color] = []
        for band in 0..<bands {
            let startRow = band * rowsPerBand
            let endRow = min(side, startRow + rowsPerBand)
            guard startRow < endRow else { continue }

            var redSum = 0, greenSum = 0, blueSum = 0, count = 0
            for y in startRow..<endRow {
                for x in 0..<side {
                    let offset = (y * side + x) * 4
                    redSum += Int(pixels[offset])
                    greenSum += Int(pixels[offset + 1])
                    blueSum += Int(pixels[offset + 2])
                    count += 1
                }
            }
            guard count > 0 else { continue }
            colors.append(Color(
                red: Double(redSum) / Double(count) / 255,
                green: Double(greenSum) / Double(count) / 255,
                blue: Double(blueSum) / Double(count) / 255))
        }
        return colors.isEmpty ? .placeholder : ArtworkPalette(colors: colors)
    }
}
