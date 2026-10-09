import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One logged contact. Contest style: a call, what was sent, what came back.
struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var callsign: String
    var time: Date
    var band: Band
    /// Dial plus audio, Hz.
    var frequency: Int
    var exchangeSent: String
    var exchangeReceived: String
    var myCallsign: String
    var myGrid: String
    var notes = ""
}

/// The log on disk: JSON in Documents, so it is visible in Files and on a
/// development build can be pulled off with `devicectl`.
@MainActor
@Observable
final class Logbook {
    private(set) var entries: [LogEntry] = []

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jtty-log.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) {
            entries = decoded.sorted { $0.time > $1.time }
        }
    }

    func add(_ entry: LogEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func update(_ entry: LogEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func remove(_ entry: LogEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }

    // MARK: - ADIF

    /// ADIF 3.1.4. JTTY has no entry in the ADIF mode list yet, so records
    /// go out as mode `DYNAMIC` with submode `JTTY`, which is what the
    /// specification asks for a mode it has not catalogued.
    var adif: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = TimeZone(identifier: "UTC")
        timeFormatter.dateFormat = "HHmmss"

        func field(_ name: String, _ value: String) -> String {
            value.isEmpty ? "" : "<\(name):\(value.utf8.count)>\(value)"
        }
        var lines = ["JTTY log export", "<ADIF_VER:5>3.1.4", "<PROGRAMID:4>JTTY", "<EOH>", ""]
        for entry in entries.reversed() {
            var record = [
                field("CALL", entry.callsign),
                field("QSO_DATE", formatter.string(from: entry.time)),
                field("TIME_ON", timeFormatter.string(from: entry.time)),
                field("BAND", entry.band.rawValue),
                field("FREQ", String(format: "%.6f", Double(entry.frequency) / 1_000_000)),
                field("MODE", "DYNAMIC"),
                field("SUBMODE", "JTTY"),
                field("STATION_CALLSIGN", entry.myCallsign),
                field("MY_GRIDSQUARE", entry.myGrid),
            ]
            let sent = entry.exchangeSent, received = entry.exchangeReceived
            if sent.hasPrefix("599") {
                record.append(field("RST_SENT", "599"))
                let rest = sent.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if let number = Int(rest) { record.append(field("STX", String(number))) }
                else { record.append(field("STX_STRING", rest)) }
            } else {
                record.append(field("STX_STRING", sent))
            }
            if received.hasPrefix("599") {
                record.append(field("RST_RCVD", "599"))
                let rest = received.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if let number = Int(rest) { record.append(field("SRX", String(number))) }
                else { record.append(field("SRX_STRING", rest)) }
            } else {
                record.append(field("SRX_STRING", received))
            }
            record.append(field("COMMENT", entry.notes))
            lines.append(record.filter { !$0.isEmpty }.joined(separator: " ") + " <EOR>")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension UTType {
    /// ADIF, as Amateur Radio Log declares it; there is no public type.
    static let adif = UTType(importedAs: "com.amateurradiolog.adif")
}

struct ADIFDocument: Transferable {
    var text: String
    var filename = "jtty-log.adi"

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .adif) { Data($0.text.utf8) }
            .suggestedFileName { $0.filename }
    }
}
