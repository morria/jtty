import CJTTY
import Foundation

/// A message turned into frames, ready to modulate.
public struct PackedMessage: Equatable, Sendable {
    /// The 34-bit payload of each frame.
    public var payloads: [UInt64]
    /// The text as the far end will render it.
    public var text: String

    public var frameCount: Int { payloads.count }
    /// On-air duration, seconds.
    public var duration: TimeInterval { Double(frameCount) * JTTYProtocol.frameDuration }
}

public enum JTTYEncodingError: LocalizedError, Equatable {
    case empty
    case tooLong
    case invalidAtom(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Nothing to send"
        case .tooLong: "Too long to send in 16 frames"
        case .invalidAtom(let what): "\(what) cannot be sent"
        }
    }
}

public enum JTTYEncoder {

    /// Pack free text into the fewest frames that reproduce it exactly.
    public static func pack(text: String, profile: ExchangeProfile = .none) throws -> PackedMessage {
        var payloads = [UInt64](repeating: 0, count: JTTYProtocol.maxFrames)
        var normalized = [CChar](repeating: 0, count: JTTYProtocol.maxTextLength + 1)
        let count = Int(jtty_pack_text(String(text.prefix(JTTYProtocol.maxTextLength)), profile.cValue, &payloads, &normalized))
        if count == 0 { throw JTTYEncodingError.empty }
        if count < 0 { throw JTTYEncodingError.tooLong }
        return PackedMessage(payloads: Array(payloads.prefix(count)), text: String(cString: normalized))
    }

    /// Pack native atoms. Structured atoms are separated on the air by an
    /// implicit space, so the rendered text joins them with one.
    public static func pack(atoms: [JTTYAtom]) throws -> PackedMessage {
        guard !atoms.isEmpty else { throw JTTYEncodingError.empty }
        guard atoms.count <= JTTYProtocol.maxFrames else { throw JTTYEncodingError.tooLong }
        var cAtoms: [jtty_atom] = []
        var parts: [String] = []
        for atom in atoms {
            guard let c = atom.cAtom, let text = atom.rendered, atom.isValid else {
                throw JTTYEncodingError.invalidAtom(atom.rendered ?? "An atom")
            }
            cAtoms.append(c)
            parts.append(text)
        }
        var payloads = [UInt64](repeating: 0, count: JTTYProtocol.maxFrames)
        guard jtty_pack_atoms(cAtoms, Int32(cAtoms.count), &payloads) else {
            throw JTTYEncodingError.invalidAtom("The message")
        }
        return PackedMessage(payloads: Array(payloads.prefix(atoms.count)), text: parts.joined(separator: " "))
    }

    /// What a frame says, with the padding spaces of a text frame shown as
    /// `~` as the receiver does internally.
    public static func text(of payload: UInt64) -> (text: String, trailingSeparator: Bool, isLast: Bool)? {
        var buffer = [CChar](repeating: 0, count: JTTYProtocol.maxTextLength + 1)
        var sep = false, eom = false
        guard jtty_unpack_frame(payload, &buffer, &sep, &eom) else { return nil }
        return (String(cString: buffer), sep, eom)
    }
}

/// Rendered transmit audio.
public struct JTTYTransmission: Sendable {
    public var message: PackedMessage
    /// Audio frequency of tone 0, Hz.
    public var frequency: Double
    /// Mono float PCM at 12 kHz, peaking at `gain`.
    public var samples: [Float]

    public var duration: TimeInterval { Double(samples.count) / JTTYProtocol.sampleRate }

    /// Fade at each end of the transmission, seconds. The waveform already
    /// ramps over an eighth of a symbol; this is belt and braces against a
    /// click if the audio engine starts mid-buffer.
    static let rampDuration: TimeInterval = 0.004

    /// - Parameters:
    ///   - gain: Linear amplitude, 0...1. Keep it well below 1: a JTTY signal
    ///     driven into the radio's ALC is a wide one.
    public init(message: PackedMessage, frequency: Double, gain: Float = 0.5) {
        self.message = message
        self.frequency = frequency
        var tones = [UInt8](repeating: 0, count: JTTYProtocol.frameSymbols * JTTYProtocol.maxFrames)
        let nsym = Int(jtty_message_tones(message.payloads, Int32(message.payloads.count), &tones))
        var audio = [Float](repeating: 0, count: nsym * JTTYProtocol.samplesPerSymbol)
        jtty_render_audio(tones, Int32(nsym), Float(frequency), &audio)
        let clamped = min(max(gain, 0), 1)
        let ramp = min(Int(Self.rampDuration * JTTYProtocol.sampleRate), audio.count / 2)
        for i in audio.indices {
            var envelope = clamped
            if i < ramp {
                envelope *= Float(i) / Float(ramp)
            } else if i >= audio.count - ramp {
                envelope *= Float(audio.count - 1 - i) / Float(ramp)
            }
            audio[i] *= envelope
        }
        samples = audio
    }
}
