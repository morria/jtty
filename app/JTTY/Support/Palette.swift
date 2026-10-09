import SwiftUI

/// The shack palette, shared with the app icon and the other apps on the
/// home screen. Used sparingly: the interface is standard iOS, and these
/// colours mark the few things that are the mode's own.
enum Palette {
    static let cream = Color(hex: 0xF2E7D3)
    static let teal = Color(hex: 0x63B3A6)
    static let sand = Color(hex: 0xEAC96F)
    static let salmon = Color(hex: 0xDE8162)
    static let slate = Color(hex: 0x24313B)

    /// Transmitting. The one state that should never be missed.
    static let transmit = salmon

    /// One hue stepped by lightness, weakest to strongest.
    static let signalSteps: [Color] = [
        Color(hex: 0x3E8395),
        Color(hex: 0x63B3A6),
        Color(hex: 0x9BD4C4),
        Color(hex: 0xD3EDE3),
    ]
    static let signalBounds: [Float] = [-12, -6, 0]

    static func signalColor(for snr: Float) -> Color {
        let index = signalBounds.firstIndex { snr <= $0 } ?? signalSteps.count - 1
        return signalSteps[index]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
