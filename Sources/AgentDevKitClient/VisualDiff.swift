import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Perceptual image comparison for visual baselines. A pixel differs when its YIQ color distance exceeds
/// `pixelTolerance`, unless it looks like anti-aliasing: an edge pixel whose neighborhood matches in either image.
public enum VisualDiff {
    public struct Result: Codable, Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let differingPixels: Int
        public let antialiasedPixels: Int
        /// differingPixels / all pixels.
        public let fraction: Double
        public let threshold: Double
        public let matched: Bool
        /// Set when the images have different sizes; nothing else is compared.
        public let sizeMismatch: [Int]?
    }

    struct Bitmap {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        func rgba(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3]))
        }
    }

    static func decode(_ data: Data) -> Bitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Bitmap(width: width, height: height, pixels: pixels) : nil
    }

    static func encodePNG(_ bitmap: Bitmap) -> Data? {
        var pixels = bitmap.pixels
        return pixels.withUnsafeMutableBytes { buffer -> Data? in
            guard let context = CGContext(data: buffer.baseAddress, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                          bytesPerRow: bitmap.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
    }

    /// The largest YIQ distance, between black and white.
    static let maxDelta = 35_215.0

    static func delta(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double), luminanceOnly: Bool = false) -> Double {
        // Blend over white so transparency compares as it is seen.
        func blend(_ c: (Double, Double, Double, Double)) -> (Double, Double, Double) {
            let alpha = c.3 / 255
            return (255 + (c.0 - 255) * alpha, 255 + (c.1 - 255) * alpha, 255 + (c.2 - 255) * alpha)
        }
        let (r1, g1, b1) = blend(a), (r2, g2, b2) = blend(b)
        let y = (r1 - r2) * 0.29889531 + (g1 - g2) * 0.58662247 + (b1 - b2) * 0.11448223
        if luminanceOnly { return y }
        let i = (r1 - r2) * 0.59597799 - (g1 - g2) * 0.27417610 - (b1 - b2) * 0.32180189
        let q = (r1 - r2) * 0.21147017 - (g1 - g2) * 0.52261711 + (b1 - b2) * 0.31114694
        return 0.5053 * y * y + 0.299 * i * i + 0.1957 * q * q
    }

    private static func hasManySiblings(_ image: Bitmap, _ x: Int, _ y: Int) -> Bool {
        let center = image.rgba(x, y)
        var zeroes = x == 0 || x == image.width - 1 || y == 0 || y == image.height - 1 ? 1 : 0
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < image.width, ny < image.height else { continue }
                if image.rgba(nx, ny) == center { zeroes += 1 }
                if zeroes > 2 { return true }
            }
        }
        return false
    }

    /// pixelmatch's anti-aliasing test: the pixel sits on an edge between a darker and a brighter neighbor,
    /// and that neighbor is part of a flat area in both images.
    private static func antialiased(_ image: Bitmap, _ x: Int, _ y: Int, _ other: Bitmap) -> Bool {
        var zeroes = x == 0 || x == image.width - 1 || y == 0 || y == image.height - 1 ? 1 : 0
        var minimum = 0.0, maximum = 0.0
        var minPoint = (0, 0), maxPoint = (0, 0)
        let center = image.rgba(x, y)
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < image.width, ny < image.height else { continue }
                let difference = delta(center, image.rgba(nx, ny), luminanceOnly: true)
                if difference == 0 {
                    zeroes += 1
                    if zeroes > 2 { return false }
                } else if difference < minimum {
                    minimum = difference
                    minPoint = (nx, ny)
                } else if difference > maximum {
                    maximum = difference
                    maxPoint = (nx, ny)
                }
            }
        }
        if minimum == 0 || maximum == 0 { return false }
        return (hasManySiblings(image, minPoint.0, minPoint.1) && hasManySiblings(other, minPoint.0, minPoint.1))
            || (hasManySiblings(image, maxPoint.0, maxPoint.1) && hasManySiblings(other, maxPoint.0, maxPoint.1))
    }

    /// Compares two PNG or JPEG images. `threshold` is the largest fraction of differing pixels that still matches;
    /// `pixelTolerance` (0…1) is how different one pixel's color may be before it counts.
    /// Returns the result and a diff image: the actual image faded, differing pixels red, anti-aliasing yellow.
    public static func compare(_ actual: Data, baseline: Data, threshold: Double = 0.01, pixelTolerance: Double = 0.1) throws -> (Result, Data?) {
        guard let a = decode(actual), let b = decode(baseline) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard a.width == b.width, a.height == b.height else {
            return (Result(width: a.width, height: a.height, differingPixels: a.width * a.height, antialiasedPixels: 0, fraction: 1,
                           threshold: threshold, matched: false, sizeMismatch: [a.width, a.height, b.width, b.height]), nil)
        }
        let limit = maxDelta * pixelTolerance * pixelTolerance
        var diff = Bitmap(width: a.width, height: a.height, pixels: [UInt8](repeating: 0, count: a.pixels.count))
        var differing = 0, antialiasedCount = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                let pa = a.rgba(x, y), pb = b.rgba(x, y)
                let distance = pa == pb ? 0 : delta(pa, pb)
                var color: (UInt8, UInt8, UInt8)
                if distance > limit {
                    if antialiased(a, x, y, b) || antialiased(b, x, y, a) {
                        antialiasedCount += 1
                        color = (255, 220, 0)
                    } else {
                        differing += 1
                        color = (230, 20, 20)
                    }
                } else {
                    // Faded grayscale of the actual image.
                    let gray = UInt8(min(255, 255 - (255 - (pa.0 * 0.299 + pa.1 * 0.587 + pa.2 * 0.114)) * 0.15))
                    color = (gray, gray, gray)
                }
                diff.pixels[i] = color.0
                diff.pixels[i + 1] = color.1
                diff.pixels[i + 2] = color.2
                diff.pixels[i + 3] = 255
            }
        }
        let fraction = Double(differing) / Double(max(1, a.width * a.height))
        let result = Result(width: a.width, height: a.height, differingPixels: differing, antialiasedPixels: antialiasedCount,
                            fraction: fraction, threshold: threshold, matched: fraction <= threshold, sizeMismatch: nil)
        return (result, encodePNG(diff))
    }

    /// Fills `{locale}` and `{appearance}` in a baseline path from a capture's reported values.
    public static func baselinePath(_ template: String, locale: String?, appearance: String?) -> String {
        template.replacingOccurrences(of: "{locale}", with: locale ?? "en")
            .replacingOccurrences(of: "{appearance}", with: appearance ?? "light")
    }
}
