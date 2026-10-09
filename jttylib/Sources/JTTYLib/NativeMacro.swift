import Foundation

/// What the operator's station is, for filling in a function-key template.
public struct MacroContext: Equatable, Sendable {
    public var myCall: String
    public var hisCall: String
    public var queuedCall: String
    public var serialNumber: Int
    public var grid: String
    public var profile: ExchangeProfile
    /// The configured exchange for Field Day (`1D EMA`) or RTTY Roundup
    /// (`CA`, or a serial if empty).
    public var configuredExchange: String

    public init(myCall: String, hisCall: String = "", queuedCall: String = "", serialNumber: Int = 1,
                grid: String = "", profile: ExchangeProfile = .none, configuredExchange: String = "") {
        self.myCall = myCall
        self.hisCall = hisCall
        self.queuedCall = queuedCall
        self.serialNumber = serialNumber
        self.grid = grid
        self.profile = profile
        self.configuredExchange = configuredExchange
    }
}

/// A function-key template compiled against the station.
public enum CompiledMacro: Equatable, Sendable {
    /// A recognised native template: these atoms, in this order.
    case native([JTTYAtom], text: String)
    /// A customised template: this text, packed automatically.
    case literal(String)
    /// A native template whose runtime data is unusable.
    case invalid(String)
}

/// The eight shipped templates and the placeholders they use.
///
/// `%M` my call, `%H` his call, `%Q` the queued call, `%E` the exchange,
/// `%N` the serial number, `%G` my grid.
public enum NativeMacro {

    public static let defaultTemplates = [
        "CQ %M CQ",
        "%H %E",
        "%H TU CQ %M CQ",
        "%M",
        "%H",
        "TU NOW %Q %E",
        "%H AGN?",
        "%E",
    ]

    public static let defaultLabels = ["CQ", "Exch", "TU CQ", "My call", "His call", "TU now", "AGN?", "Exch only"]

    /// Whitespace-normalised, upper-cased, so a template typed with an extra
    /// space still counts as the native one.
    static func canonical(_ template: String) -> String {
        template.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    public static func compile(_ template: String, context: MacroContext) -> CompiledMacro {
        let key = canonical(template)
        switch key {
        case "CQ %M CQ":
            return callAtom(.cq, context.myCall, "your callsign")
        case "%H %E", "%H 599 %N":
            return combine(callAtom(.call, context.hisCall, "his callsign"), exchange(context))
        case "%H TU CQ %M CQ":
            return combine(callAtom(.callTu, context.hisCall, "his callsign"), callAtom(.cq, context.myCall, "your callsign"))
        case "%M":
            return callAtom(.call, context.myCall, "your callsign")
        case "%H":
            return callAtom(.call, context.hisCall, "his callsign")
        case "TU NOW %Q %E", "TU NOW %Q 599 %N":
            return combine(callAtom(.tuNow, context.queuedCall, "the queued callsign"), exchange(context))
        case "%H AGN?":
            return callAtom(.agn, context.hisCall, "his callsign")
        case "%E", "599 %N":
            return exchange(context)
        case "%G":
            return gridAtom(context.grid, full: false)
        case "599 %G":
            return gridAtom(context.grid, full: true)
        default:
            if let phrase = ControlPhrase.matching(key) {
                return .native([.control(phrase)], text: phrase.text)
            }
            return .literal(expand(template, context: context))
        }
    }

    /// Plain substitution for a customised template.
    public static func expand(_ template: String, context: MacroContext) -> String {
        var text = template
        let exchangeText: String
        if case .native(_, let rendered) = exchange(context) { exchangeText = rendered } else { exchangeText = "" }
        for (token, value) in [
            ("%M", context.myCall), ("%H", context.hisCall), ("%Q", context.queuedCall),
            ("%E", exchangeText), ("%N", String(format: "%03d", context.serialNumber)), ("%G", context.grid),
        ] {
            text = text.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        return text
    }

    private static func callAtom(_ action: JTTYAtom.CallAction, _ callsign: String, _ what: String) -> CompiledMacro {
        let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        if call.isEmpty { return .invalid("Enter \(what) first") }
        let atom = JTTYAtom.call(action, call)
        guard atom.isValid, let text = atom.rendered else {
            return .invalid("\(call) is not a standard callsign; type the message instead")
        }
        return .native([atom], text: text)
    }

    private static func gridAtom(_ grid: String, full: Bool) -> CompiledMacro {
        let g = String(grid.uppercased().prefix(4))
        let atom = JTTYAtom.grid(g, full: full)
        guard atom.isValid, let text = atom.rendered else { return .invalid("Set a four-character grid first") }
        return .native([atom], text: text)
    }

    /// The configured exchange as a typed atom.
    public static func exchange(_ context: MacroContext) -> CompiledMacro {
        let configured = context.configuredExchange.trimmingCharacters(in: .whitespaces).uppercased()
        switch context.profile {
        case .none:
            return serial(context.serialNumber)
        case .fieldDay:
            let parts = configured.split(separator: " ")
            guard parts.count == 2, parts[0].count >= 2,
                  let count = Int(parts[0].dropLast()), let letter = parts[0].last else {
                return .invalid("Set the Field Day exchange, like 1D EMA")
            }
            let atom = JTTYAtom.classSection(count: count, classLetter: letter, section: String(parts[1]))
            guard atom.isValid, let text = atom.rendered else {
                return .invalid("\(configured) is not a valid Field Day class and section")
            }
            return .native([atom], text: text)
        case .rttyRoundup:
            if configured.isEmpty || configured == "#" || Int(configured) != nil && configured != "DX" {
                return serial(context.serialNumber)
            }
            let atom = JTTYAtom.location(.stateProvince, configured, full: true)
            guard atom.isValid, let text = atom.rendered else {
                return .invalid("\(configured) is not a two or three character state or province")
            }
            return .native([atom], text: text)
        }
    }

    private static func serial(_ number: Int) -> CompiledMacro {
        let atom = JTTYAtom.number(.serial, number, full: true)
        guard atom.isValid, let text = atom.rendered else { return .invalid("Serial number out of range") }
        return .native([atom], text: text)
    }

    private static func combine(_ a: CompiledMacro, _ b: CompiledMacro) -> CompiledMacro {
        switch (a, b) {
        case (.native(let x, let tx), .native(let y, let ty)):
            return .native(x + y, text: tx + " " + ty)
        case (.invalid(let why), _), (_, .invalid(let why)):
            return .invalid(why)
        default:
            return .invalid("Cannot build this message")
        }
    }
}
