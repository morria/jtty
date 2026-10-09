import CJTTY
import Foundation

/// The numbers that define the mode.
public enum JTTYProtocol {
    public static let sampleRate: Double = 12000
    public static let samplesPerSymbol = Int(JTTY_NSPS)
    public static let baud = sampleRate / Double(samplesPerSymbol)
    public static let syncSymbols = Int(JTTY_SYNC_SYMBOLS)
    public static let dataSymbols = Int(JTTY_DATA_SYMBOLS)
    public static let frameSymbols = Int(JTTY_FRAME_SYMBOLS)
    public static let frameSamples = Int(JTTY_FRAME_SAMPLES)
    /// Seconds per frame: 59 symbols at 31.25 baud.
    public static let frameDuration = Double(frameSamples) / sampleRate
    public static let maxFrames = Int(JTTY_MAX_FRAMES)
    public static let maxTextLength = Int(JTTY_MAX_TEXT)
    /// The receiver advances a quarter frame at a time.
    public static let stepSamples = Int(JTTY_STEP_SAMPLES)
    public static let chunkSamples = Int(JTTY_CHUNK_SAMPLES)
    /// Occupied bandwidth, Hz.
    public static let bandwidth: Double = 127

    /// The source alphabet, in six-bit order.
    public static let alphabet: String = withUnsafePointer(to: jtty_alphabet) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
    }
}

/// Which contest exchange the operator is sending. Decides how `%E` is
/// parsed and whether free text has its serials canonicalised.
public enum ExchangeProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case fieldDay
    case rttyRoundup

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Serial number"
        case .fieldDay: "Field Day"
        case .rttyRoundup: "RTTY Roundup"
        }
    }

    var cValue: Int32 {
        switch self {
        case .none: Int32(JTTY_PROFILE_UNKNOWN)
        case .fieldDay: Int32(JTTY_PROFILE_FIELD_DAY)
        case .rttyRoundup: Int32(JTTY_PROFILE_RTTY_ROUNDUP)
        }
    }
}

/// The eighteen control phrases the protocol carries in one frame.
public enum ControlPhrase: Int, CaseIterable, Sendable {
    case agn = 0, call, agnCall, nr, agnNr, exch, state, section, zone, grid
    case rprt, qslTu, tu, qrz, qsoB4, wait, nil_, ok

    public var text: String {
        withUnsafeBytes(of: jtty_control_phrases) { raw in
            String(cString: raw.load(fromByteOffset: rawValue * MemoryLayout<UnsafePointer<CChar>?>.stride, as: UnsafePointer<CChar>.self))
        }
    }

    public static func matching(_ text: String) -> ControlPhrase? {
        allCases.first { $0.text == text }
    }
}

/// One unit of meaning on the air: a callsign action, a typed exchange, a
/// control phrase, a grid, or five characters of text.
public enum JTTYAtom: Equatable, Sendable {
    public enum CallAction: Int, Sendable {
        case cq = 0, call, tuCq, callTu, agn, tuNow
    }
    public enum NumberKind: Int, Sendable {
        case serial = 0, cqZone, ituZone, age, power, check, licenseYear, generic
    }
    public enum LocationKind: Int, Sendable {
        case stateProvince = 0, section, countryPrefix, qth, adminCode
    }

    case call(CallAction, String)
    case number(NumberKind, Int, full: Bool)
    case location(LocationKind, String, full: Bool)
    case zoneLocation(zone: Int, token: String)
    case classSection(count: Int, classLetter: Character, section: String)
    case serialTime(serial: Int, minuteOfDay: Int, full: Bool)
    case control(ControlPhrase)
    case grid(String, full: Bool)
    case text(String)

    var cAtom: jtty_atom? {
        var a = jtty_atom()
        func setText(_ s: String) -> Bool {
            guard s.utf8.count <= 13 else { return false }
            withUnsafeMutableBytes(of: &a.text) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                for (i, byte) in s.utf8.enumerated() { buffer[i] = byte }
            }
            return true
        }
        switch self {
        case .call(let action, let callsign):
            a.kind = Int32(JTTY_ATOM_CALL)
            a.subtype = Int32(action.rawValue)
            guard setText(callsign) else { return nil }
        case .number(let kind, let value, let full):
            a.kind = Int32(JTTY_ATOM_EXCH_NUM)
            a.subtype = Int32(kind.rawValue)
            a.role = full ? 1 : 0
            a.value = Int32(clamping: value)
        case .location(let kind, let token, let full):
            a.kind = Int32(JTTY_ATOM_EXCH_LOC)
            a.subtype = Int32(kind.rawValue)
            a.role = full ? 1 : 0
            guard setText(token) else { return nil }
        case .zoneLocation(let zone, let token):
            a.kind = Int32(JTTY_ATOM_EXCH_PAIR)
            a.subtype = Int32(JTTY_PAIR_ZONE_LOC3)
            a.value = Int32(clamping: zone)
            guard setText(token) else { return nil }
        case .classSection(let count, let letter, let section):
            a.kind = Int32(JTTY_ATOM_EXCH_PAIR)
            a.subtype = Int32(JTTY_PAIR_CLASS_SECTION)
            a.value = Int32(clamping: count)
            a.value2 = jtty_section_index(section)
            guard setText(String(letter)) else { return nil }
        case .serialTime(let serial, let minute, let full):
            a.kind = Int32(JTTY_ATOM_EXCH_NUM_TIME)
            a.role = full ? 1 : 0
            a.value = Int32(clamping: serial)
            a.value2 = Int32(clamping: minute)
        case .control(let phrase):
            a.kind = Int32(JTTY_ATOM_CONTROL)
            a.subtype = Int32(phrase.rawValue)
        case .grid(let grid, let full):
            a.kind = Int32(JTTY_ATOM_GRID4)
            a.role = full ? 1 : 0
            guard setText(grid) else { return nil }
        case .text(let text):
            a.kind = Int32(JTTY_ATOM_TEXT5)
            guard setText(String(text.prefix(5))) else { return nil }
        }
        return a
    }

    /// The canonical text of this atom, or nil if it is not valid.
    public var rendered: String? {
        guard var a = cAtom else { return nil }
        var buffer = [CChar](repeating: 0, count: JTTYProtocol.maxTextLength + 1)
        guard jtty_render_atom(&a, &buffer) else { return nil }
        return String(cString: buffer)
    }

    /// Whether the atom can be put on the air.
    public var isValid: Bool {
        guard var a = cAtom else { return false }
        var payload: UInt64 = 0
        return jtty_pack_atom(&a, false, &payload)
    }
}

/// Whether a callsign fits the protocol's compact callsign field. Portable
/// and compound calls do not, and go as text.
public func isStandardCallsign(_ callsign: String) -> Bool {
    jtty_is_standard_call(callsign)
}

/// Fold text into the source alphabet the way the encoder will.
public func normalizedText(_ text: String) -> String {
    var buffer = [CChar](repeating: 0, count: JTTYProtocol.maxTextLength + 1)
    jtty_normalize(text, &buffer)
    return String(cString: buffer)
}
