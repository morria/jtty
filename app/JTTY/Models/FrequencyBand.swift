import Foundation

/// A cluster of traffic on one frequency: one conversation.
///
/// JTTY contacts are worked on a single frequency, and a signal is 127 Hz
/// wide, so everything within 60 Hz of each other is one conversation and
/// anything further apart is the next one over. Bands are built from the
/// transcript each time it changes rather than stored, so there is no state
/// to keep in step with it.
struct FrequencyBand: Identifiable, Equatable {
    /// The frequency of the most recent message, Hz.
    var frequency: Double
    var lines: [TranscriptLine]

    var id: Int { Int(frequency.rounded()) }
    var latest: TranscriptLine? { lines.last }
    var latestTime: Date { latest?.time ?? .distantPast }
    var isActive: Bool { latest?.isInProgress ?? false }

    /// Callsigns heard on the band, most recent first, without our own.
    func callsigns(excluding mine: String) -> [String] {
        var seen: [String] = []
        for line in lines.reversed() where line.kind == .received {
            if let call = line.callsign, call != mine, !seen.contains(call) { seen.append(call) }
        }
        return seen
    }

    /// Group a transcript into bands. Newest message first, so each band
    /// is centred on its latest frequency; older messages join the band
    /// they are nearest to, within the half width.
    static func bands(from transcript: [TranscriptLine], extra: [Double], halfWidth: Double) -> [FrequencyBand] {
        var bands: [FrequencyBand] = []
        for line in transcript.reversed() {
            if let index = bands.indices.min(by: { abs(bands[$0].frequency - line.frequency) < abs(bands[$1].frequency - line.frequency) }),
               abs(bands[index].frequency - line.frequency) <= halfWidth {
                bands[index].lines.insert(line, at: 0)
            } else {
                bands.append(FrequencyBand(frequency: line.frequency, lines: [line]))
            }
        }
        for frequency in extra where !bands.contains(where: { abs($0.frequency - frequency) <= halfWidth }) {
            bands.append(FrequencyBand(frequency: frequency, lines: []))
        }
        return bands.sorted { $0.latestTime > $1.latestTime }
    }
}
