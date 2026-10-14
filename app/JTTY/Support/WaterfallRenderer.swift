import CoreGraphics
import Foundation
import SwiftUI

/// The waterfall bitmap, kept up to date one line at a time.
///
/// Ten lines a second arrive, and the obvious way, rebuilding the whole
/// picture from the stored lines on every update, was a quarter-second of
/// main-thread work a second once the sort to find the noise floor was
/// counted. This keeps the pixels, shifts them up a row, and paints only the
/// new line; the floor is tracked from the new line alone and smoothed.
@MainActor
@Observable
final class WaterfallRenderer {
    static let height = 90

    private(set) var image: CGImage?
    @ObservationIgnored private var pixels: [UInt8] = []
    @ObservationIgnored private var width = 0
    @ObservationIgnored private var floor: Float?
    @ObservationIgnored private var ceiling: Float?
    @ObservationIgnored private var scratch: [Float] = []

    func reset() {
        pixels.removeAll()
        width = 0
        floor = nil
        ceiling = nil
        image = nil
    }

    func append(_ line: RadioAudioController.SpectrumLine) {
        let magnitudes = line.magnitudes
        guard !magnitudes.isEmpty else { return }
        if magnitudes.count != width {
            width = magnitudes.count
            pixels = [UInt8](repeating: 0, count: width * Self.height * 4)
            // Empty rows are the floor colour, not black.
            let (r, g, b) = Self.colour(0)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
        // Floor: the median of this line; ceiling: its 99th percentile, at
        // least 30 dB up. Both smoothed so the picture does not flicker.
        scratch = magnitudes
        scratch.sort()
        let lineFloor = scratch[scratch.count / 2]
        let lineCeiling = max(lineFloor + 30, scratch[scratch.count * 99 / 100])
        floor = floor.map { 0.9 * $0 + 0.1 * lineFloor } ?? lineFloor
        ceiling = ceiling.map { 0.9 * $0 + 0.1 * lineCeiling } ?? lineCeiling
        let lo = floor!, span = max(ceiling! - lo, 1)

        let rowBytes = width * 4
        pixels.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            memmove(base, base + rowBytes, rowBytes * (Self.height - 1))
            let last = base + rowBytes * (Self.height - 1)
            for (x, value) in magnitudes.enumerated() {
                let t = max(0, min(1, (value - lo) / span))
                let (r, g, b) = Self.colour(t)
                let p = last + x * 4
                p.storeBytes(of: r, as: UInt8.self)
                p.storeBytes(of: g, toByteOffset: 1, as: UInt8.self)
                p.storeBytes(of: b, toByteOffset: 2, as: UInt8.self)
                p.storeBytes(of: 255, toByteOffset: 3, as: UInt8.self)
            }
        }
        if let provider = CGDataProvider(data: Data(pixels) as CFData) {
            image = CGImage(
                width: width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    /// Slate through teal to cream, the palette's own waterfall, as a
    /// 256-entry table rather than a blend per pixel.
    private static let table: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
        let t = Float(i) / 255
        let stops: [(Float, (Float, Float, Float))] = [
            (0.0, (0.098, 0.137, 0.169)), (0.45, (0.243, 0.514, 0.584)),
            (0.75, (0.388, 0.702, 0.651)), (1.0, (0.949, 0.906, 0.827)),
        ]
        var lower = stops[0], upper = stops[stops.count - 1]
        for k in 0..<stops.count - 1 where t >= stops[k].0 && t <= stops[k + 1].0 {
            lower = stops[k]; upper = stops[k + 1]; break
        }
        let f = (t - lower.0) / max(upper.0 - lower.0, 0.001)
        func mix(_ a: Float, _ b: Float) -> UInt8 { UInt8(max(0, min(255, (a + (b - a) * f) * 255))) }
        return (mix(lower.1.0, upper.1.0), mix(lower.1.1, upper.1.1), mix(lower.1.2, upper.1.2))
    }

    private static func colour(_ t: Float) -> (UInt8, UInt8, UInt8) {
        table[Int(max(0, min(255, (t * 255).rounded())))]
    }
}
