import SwiftUI

/// Input level, so the operator can set the interface gain without guessing.
struct InputLevelMeter: View {
    let level: Float
    var segments = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Float(index + 1) / Float(segments)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(at: threshold, lit: level >= threshold))
                    .frame(width: 3, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(at threshold: Float, lit: Bool) -> Color {
        guard lit else { return Color.primary.opacity(0.12) }
        if threshold > 0.85 { return Palette.salmon }
        if threshold > 0.65 { return Palette.sand }
        return Palette.teal
    }
}

/// A small labelled pill.
struct StatusChip: View {
    let text: String
    var color: Color = Palette.teal
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text)
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// The last few seconds of the passband, 200 to 2800 Hz across, time down.
///
/// Drawn into a bitmap rather than as shapes: a line is nine hundred
/// values and there are ninety of them, and a view that redraws that many
/// rectangles ten times a second is a view that drops frames.
struct WaterfallView: View {
    let lines: [RadioAudioController.SpectrumLine]
    let rxFrequency: Double
    let txFrequency: Double
    var onTap: ((Double) -> Void)?

    private static let minHz = RadioAudioController.SpectrumLine.minFrequency
    private static let maxHz = RadioAudioController.SpectrumLine.maxFrequency

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image = Self.image(for: lines) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Rectangle().fill(Palette.slate)
                }
                marker(at: rxFrequency, in: geometry.size, color: Palette.teal, label: "RX")
                if abs(txFrequency - rxFrequency) > 1 {
                    marker(at: txFrequency, in: geometry.size, color: Palette.salmon, label: "TX")
                }
                ForEach([500, 1000, 1500, 2000, 2500], id: \.self) { hz in
                    Text("\(hz)")
                        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.cream.opacity(0.7))
                        .position(x: x(for: Double(hz), width: geometry.size.width), y: geometry.size.height - 7)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let hz = Self.minHz + (Self.maxHz - Self.minHz) * location.x / geometry.size.width
                onTap?((hz / 10).rounded() * 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Waterfall")
        .accessibilityHint("Tap to set the frequency")
    }

    private func x(for hz: Double, width: CGFloat) -> CGFloat {
        width * (hz - Self.minHz) / (Self.maxHz - Self.minHz)
    }

    private func marker(at hz: Double, in size: CGSize, color: Color, label: String) -> some View {
        // A JTTY signal is 127 Hz wide and the frequency is tone 0, so the
        // marker is a bracket over the signal rather than a line.
        let left = x(for: hz, width: size.width)
        let right = x(for: hz + 127, width: size.width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(0.18)).frame(width: right - left, height: size.height).offset(x: left)
            Rectangle().fill(color).frame(width: 1.5, height: size.height).offset(x: left)
            Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(color).offset(x: left + 3, y: 2)
        }
    }

    /// Lines to pixels, newest at the bottom.
    private static func image(for lines: [RadioAudioController.SpectrumLine]) -> CGImage? {
        guard let width = lines.first?.magnitudes.count, width > 0 else { return nil }
        let height = AppModel.spectrumHistory
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Level the floor per image: the median of everything is noise, and
        // the top of the range is a strong signal.
        let all = lines.flatMap(\.magnitudes).sorted()
        let floor = all[all.count / 2]
        let ceiling = max(floor + 30, all[all.count * 99 / 100])
        for (row, line) in lines.enumerated() {
            let y = height - lines.count + row
            guard y >= 0, line.magnitudes.count == width else { continue }
            for (x, value) in line.magnitudes.enumerated() {
                let t = max(0, min(1, (value - floor) / (ceiling - floor)))
                let (r, g, b) = colour(t)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Slate through teal to cream, the palette's own waterfall.
    private static func colour(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, (Float, Float, Float))] = [
            (0.0, (0.098, 0.137, 0.169)),
            (0.45, (0.243, 0.514, 0.584)),
            (0.75, (0.388, 0.702, 0.651)),
            (1.0, (0.949, 0.906, 0.827)),
        ]
        var lower = stops[0], upper = stops[stops.count - 1]
        for i in 0..<stops.count - 1 where t >= stops[i].0 && t <= stops[i + 1].0 {
            lower = stops[i]
            upper = stops[i + 1]
            break
        }
        let span = max(upper.0 - lower.0, 0.001)
        let f = (t - lower.0) / span
        func mix(_ a: Float, _ b: Float) -> UInt8 { UInt8(max(0, min(255, (a + (b - a) * f) * 255))) }
        return (mix(lower.1.0, upper.1.0), mix(lower.1.1, upper.1.1), mix(lower.1.2, upper.1.2))
    }
}
