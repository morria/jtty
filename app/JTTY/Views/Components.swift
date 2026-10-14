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
/// Takes the bitmap the renderer keeps up to date, so this view's own work
/// is drawing one image and three markers.
struct WaterfallView: View {
    let image: CGImage?
    let rxFrequency: Double
    let txFrequency: Double
    var onTap: ((Double) -> Void)?

    private static let minHz = RadioAudioController.SpectrumLine.minFrequency
    private static let maxHz = RadioAudioController.SpectrumLine.maxFrequency

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image {
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

}
