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

    /// Signal strength, weakest to strongest: grey for a decode at the
    /// threshold, then the teal deepening. Every step has to read on white
    /// as well as on slate, which rules out the pale end of the hue.
    static let signalSteps: [Color] = [
        Color.secondary,
        Color(hex: 0x4A96A3),
        teal,
        Color(hex: 0x2E8C7C),
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
