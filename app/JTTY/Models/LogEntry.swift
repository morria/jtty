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
    /// Their Maidenhead locator, when they sent one.
    var theirGrid = ""
    /// Where they are, as the QSO app records it: operator name, town,
    /// state or province, country. Filled from the conversation where it
    /// said, otherwise by hand.
    var name = ""
    var qth = ""
    var state = ""
    var country = ""
    /// Whether QRZ has this contact.
    var uploadedToQRZ = false

    enum CodingKeys: String, CodingKey {
        case id, callsign, time, band, frequency, exchangeSent, exchangeReceived, myCallsign, myGrid, notes, theirGrid
        case name, qth, state, country, uploadedToQRZ
    }

    init(id: UUID = UUID(), callsign: String, time: Date, band: Band, frequency: Int, exchangeSent: String,
         exchangeReceived: String, myCallsign: String, myGrid: String, notes: String = "", theirGrid: String = "",
         name: String = "", qth: String = "", state: String = "", country: String = "") {
        self.id = id
        self.name = name
        self.qth = qth
        self.state = state
        self.country = country
        self.callsign = callsign
        self.time = time
        self.band = band
        self.frequency = frequency
        self.exchangeSent = exchangeSent
        self.exchangeReceived = exchangeReceived
        self.myCallsign = myCallsign
        self.myGrid = myGrid
        self.notes = notes
        self.theirGrid = theirGrid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        callsign = try c.decodeIfPresent(String.self, forKey: .callsign) ?? ""
        time = try c.decodeIfPresent(Date.self, forKey: .time) ?? Date()
        band = try c.decodeIfPresent(Band.self, forKey: .band) ?? .m20
        frequency = try c.decodeIfPresent(Int.self, forKey: .frequency) ?? 0
        exchangeSent = try c.decodeIfPresent(String.self, forKey: .exchangeSent) ?? ""
        exchangeReceived = try c.decodeIfPresent(String.self, forKey: .exchangeReceived) ?? ""
        myCallsign = try c.decodeIfPresent(String.self, forKey: .myCallsign) ?? ""
        myGrid = try c.decodeIfPresent(String.self, forKey: .myGrid) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        theirGrid = try c.decodeIfPresent(String.self, forKey: .theirGrid) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        qth = try c.decodeIfPresent(String.self, forKey: .qth) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        uploadedToQRZ = try c.decodeIfPresent(Bool.self, forKey: .uploadedToQRZ) ?? false
    }

    /// One ADIF record. JTTY has no entry in the ADIF mode list yet, so it
    /// goes out as mode `DYNAMIC` with submode `JTTY`, which is what the
    /// specification asks for a mode it has not catalogued.
    var adifRecord: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = TimeZone(identifier: "UTC")
        timeFormatter.dateFormat = "HHmmss"
        func field(_ name: String, _ value: String) -> String {
            value.isEmpty ? "" : "<\(name):\(value.utf8.count)>\(value)"
        }
        var record = [
            field("CALL", callsign),
            field("QSO_DATE", formatter.string(from: time)),
            field("TIME_ON", timeFormatter.string(from: time)),
            field("BAND", band.rawValue),
            field("FREQ", String(format: "%.6f", Double(frequency) / 1_000_000)),
            field("MODE", "DYNAMIC"),
            field("SUBMODE", "JTTY"),
            field("STATION_CALLSIGN", myCallsign),
            field("MY_GRIDSQUARE", myGrid),
            field("GRIDSQUARE", theirGrid),
            field("NAME", name),
            field("QTH", qth),
            field("STATE", state),
            field("COUNTRY", country),
        ]
        // A `599 ...` exchange is an RST plus a serial or string; a decibel
        // report is the RST on its own, as FT8 logs do; anything else is the
        // exchange string.
        func exchangeFields(_ exchange: String, rst: String, number: String, string: String) -> [String] {
            let dB = exchange.replacingOccurrences(of: " DB", with: "").replacingOccurrences(of: " dB", with: "")
            if exchange.hasPrefix("599") {
                let rest = exchange.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { return [field(rst, "599")] }
                if let n = Int(rest) { return [field(rst, "599"), field(number, String(n))] }
                return [field(rst, "599"), field(string, rest)]
            }
            if let n = Int(dB), (-40...40).contains(n) { return [field(rst, String(format: "%+03d", n))] }
            return [field(string, exchange)]
        }
        record += exchangeFields(exchangeSent, rst: "RST_SENT", number: "STX", string: "STX_STRING")
        record += exchangeFields(exchangeReceived, rst: "RST_RCVD", number: "SRX", string: "SRX_STRING")
        record.append(field("COMMENT", notes))
        return record.filter { !$0.isEmpty }.joined(separator: " ") + " <EOR>"
    }
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

    var adif: String {
        let header = ["JTTY log export", "<ADIF_VER:5>3.1.4", "<PROGRAMID:4>JTTY", "<EOH>", ""]
        return (header + entries.reversed().map(\.adifRecord)).joined(separator: "\n") + "\n"
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
