import Foundation
import JTTYLib

/// Everything the operator has set, as one JSON blob in `UserDefaults`.
struct Preferences: Codable, Equatable, Sendable {

    // MARK: - Station

    var callsign = ""
    var grid = ""

    // MARK: - Operating

    var band: Band = .m20
    /// The radio's dial frequency, Hz, for the log.
    var dialFrequency: Int = Band.m20.suggestedDialFrequency

    /// The same in kHz, which is how a dial reads.
    var dialKilohertz: Double {
        get { Double(dialFrequency) / 1000 }
        set { dialFrequency = Int((newValue * 1000).rounded()) }
    }

    /// Audio frequency of tone 0 when transmitting, Hz.
    var txFrequency: Double = 1500
    /// Where to listen most carefully, Hz, and how far either side.
    var rxFrequency: Double = 1500
    var rxTolerance: Double = 100
    /// Keep the receive frequency on the transmit frequency.
    var rxFollowsTx = true
    /// Before calling CQ, move to the quietest spot near the transmit
    /// frequency rather than sitting wherever the slider was left.
    var choosesClearFrequency = true
    /// When the station last transmitted. The band setting is only trusted
    /// for an hour after that: nothing ties it to the radio, and a radio
    /// retuned during a break is how a morning ends up logged on the wrong
    /// band.
    var lastTransmitAt: Date?
    /// Also look for signals right across the passband, not only around the
    /// receive frequency and the calling area.
    var searchesWholePassband = true

    /// Transmit level as a fraction of full scale. Low by default: the
    /// radio's ALC should see a signal it does not have to compress.
    var txGain: Double = 0.35

    // MARK: - Exchange

    var exchangeProfile: ExchangeProfile = .none
    /// The Field Day class and section, or the RTTY Roundup state.
    var configuredExchange = ""
    /// Next serial number to send. Persisted because it has to survive a
    /// restart mid-contest.
    var serialNumber = 1

    /// Contest operating: serial numbers, a queued station, and the
    /// contest exchange profiles. Off, a contact is a conversation.
    var contestMode = false

    /// The eight quick messages, one set for each way of operating.
    var contestMacros: [String] = NativeMacro.defaultTemplates
    var casualMacros: [String] = NativeMacro.casualTemplates

    var macros: [String] {
        get { contestMode ? contestMacros : casualMacros }
        set { if contestMode { contestMacros = newValue } else { casualMacros = newValue } }
    }
    var macroLabels: [String] { contestMode ? NativeMacro.defaultLabels : NativeMacro.casualLabels }

    /// Upload logged contacts to the QRZ logbook. The key lives in the
    /// keychain, not here.
    var logsToQRZ = false
    /// Whether the one-time offer to set QRZ up has been made.
    var qrzOfferMade = false

    var hasCompletedSetup = false

    var canTransmit: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the band needs confirming before the next transmission.
    var bandIsStale: Bool {
        guard let lastTransmitAt else { return true }
        return Date().timeIntervalSince(lastTransmitAt) > 3600
    }

    func normalized() -> Preferences {
        var copy = self
        copy.callsign = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        copy.grid = grid.trimmingCharacters(in: .whitespaces).uppercased()
        copy.configuredExchange = configuredExchange.trimmingCharacters(in: .whitespaces).uppercased()
        if copy.contestMacros.count != 8 { copy.contestMacros = NativeMacro.defaultTemplates }
        if copy.casualMacros.count != 8 { copy.casualMacros = NativeMacro.casualTemplates }
        copy.serialNumber = max(0, min(copy.serialNumber, 131071))
        copy.txFrequency = min(max(copy.txFrequency, 200), 2700)
        copy.rxFrequency = min(max(copy.rxFrequency, 200), 2700)
        return copy
    }

    // MARK: - Persistence

    private static let key = "preferences"

    init() {}

    /// Every field falls back to its default when missing, so adding a
    /// setting in a new version never throws away the callsign and
    /// everything else saved by the old one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = Preferences()
        callsign = get(.callsign, defaults.callsign)
        grid = get(.grid, defaults.grid)
        band = get(.band, defaults.band)
        dialFrequency = get(.dialFrequency, defaults.dialFrequency)
        txFrequency = get(.txFrequency, defaults.txFrequency)
        rxFrequency = get(.rxFrequency, defaults.rxFrequency)
        rxTolerance = get(.rxTolerance, defaults.rxTolerance)
        rxFollowsTx = get(.rxFollowsTx, defaults.rxFollowsTx)
        choosesClearFrequency = get(.choosesClearFrequency, defaults.choosesClearFrequency)
        lastTransmitAt = get(.lastTransmitAt, defaults.lastTransmitAt)
        searchesWholePassband = get(.searchesWholePassband, defaults.searchesWholePassband)
        txGain = get(.txGain, defaults.txGain)
        exchangeProfile = get(.exchangeProfile, defaults.exchangeProfile)
        configuredExchange = get(.configuredExchange, defaults.configuredExchange)
        serialNumber = get(.serialNumber, defaults.serialNumber)
        contestMode = get(.contestMode, defaults.contestMode)
        contestMacros = get(.contestMacros, defaults.contestMacros)
        casualMacros = get(.casualMacros, defaults.casualMacros)
        logsToQRZ = get(.logsToQRZ, defaults.logsToQRZ)
        qrzOfferMade = get(.qrzOfferMade, defaults.qrzOfferMade)
        hasCompletedSetup = get(.hasCompletedSetup, defaults.hasCompletedSetup)
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return decoded.normalized()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
