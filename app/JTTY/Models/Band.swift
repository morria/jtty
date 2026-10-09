import Foundation

/// A band, for the log. JTTY has no settled watering holes yet, so the dial
/// frequency is typed rather than looked up; the band is just a label the
/// log and the operator agree on.
enum Band: String, CaseIterable, Codable, Identifiable, Sendable {
    case m160 = "160m", m80 = "80m", m60 = "60m", m40 = "40m", m30 = "30m", m20 = "20m"
    case m17 = "17m", m15 = "15m", m12 = "12m", m10 = "10m", m6 = "6m", m2 = "2m"

    var id: String { rawValue }

    /// Where RTTY-style activity conventionally sits, as a starting point
    /// for the dial frequency field.
    var suggestedDialFrequency: Int {
        switch self {
        case .m160: 1_838_000
        case .m80: 3_580_000
        case .m60: 5_357_000
        case .m40: 7_080_000
        case .m30: 10_140_000
        case .m20: 14_080_000
        case .m17: 18_105_000
        case .m15: 21_080_000
        case .m12: 24_920_000
        case .m10: 28_080_000
        case .m6: 50_300_000
        case .m2: 144_300_000
        }
    }
}
