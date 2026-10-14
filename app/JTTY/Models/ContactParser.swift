import Foundation
import JTTYLib

/// Reads a contact out of the messages on one frequency.
///
/// JTTY carries no structure above the frame, so what was exchanged has to
/// be read back out of the text: a callsign, a grid, a `599 123`, a
/// `1D EMA`, a `599 05 NWT`, a signal report in decibels, a name. The
/// parser takes the message that was pressed and everything heard and sent
/// on that frequency within a few minutes of it, and fills in what it can.
/// Nothing it guesses is final; the sheet it feeds is there to be checked.
enum ContactParser {

    struct Draft: Equatable {
        var callsign = ""
        var theirGrid = ""
        var exchangeReceived = ""
        var exchangeSent = ""
        var name = ""
        var time = Date()
        var frequency: Double = 0
    }

    /// How far either side of the pressed message the conversation is read.
    static let window: TimeInterval = 15 * 60

    static func draft(from line: TranscriptLine, conversation: [TranscriptLine],
                      myCallsign: String, myGrid: String) -> Draft {
        var draft = Draft(time: line.time, frequency: line.frequency)
        let my = myCallsign.uppercased()
        let myGrid4 = String(myGrid.uppercased().prefix(4))
        let nearby = conversation
            .filter { abs($0.time.timeIntervalSince(line.time)) <= window }
            .sorted { $0.time < $1.time }

        // The pressed message first, then the rest, so what was pressed wins.
        let received = [line] + nearby.filter { $0.kind == .received && $0.id != line.id }
        for message in received {
            let found = parse(message.text, excludingCall: my, excludingGrid: myGrid4)
            if draft.callsign.isEmpty, let call = found.callsign { draft.callsign = call }
            if draft.theirGrid.isEmpty, let grid = found.grid { draft.theirGrid = grid }
            if draft.exchangeReceived.isEmpty, let exchange = found.exchange { draft.exchangeReceived = exchange }
            if draft.name.isEmpty, let name = found.name { draft.name = name }
        }
        // What we sent them: the last exchange-like thing in our own messages.
        for message in nearby.filter({ $0.kind == .sent }).reversed() {
            let found = parse(message.text, excludingCall: draft.callsign, excludingGrid: draft.theirGrid)
            if let exchange = found.exchange { draft.exchangeSent = exchange; break }
            if let grid = found.grid { draft.exchangeSent = grid; break }
        }
        return draft
    }

    struct Found {
        var callsign: String?
        var grid: String?
        var exchange: String?
        var name: String?
    }

    static let skipWords: Set<String> = ["CQ", "TU", "NOW", "AGN?", "AGN", "DE", "QRZ?", "QRZ", "599", "DX", "TEST", "UR", "RR", "R", "73", "QSL", "NR", "NR?", "OK", "OK?", "PSE", "K", "KN", "BK", "SK", "NAME", "OP", "QTH", "RST", "RSQ", "RPRT", "RPRT?", "WX", "RIG", "ANT", "PWR", "HR", "ES", "HW?", "HW", "CPY", "CPI", "FB", "GM", "GA", "GE", "GN", "TNX", "TKS", "VY", "AND", "THE", "IS", "IN", "MY", "HI"]

    static func parse(_ text: String, excludingCall: String, excludingGrid: String) -> Found {
        var found = Found()
        let words = text.uppercased().split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if found.callsign == nil, !skipWords.contains(clean), clean != excludingCall, looksLikeCallsign(clean) {
                found.callsign = clean
            }
            if found.grid == nil, isGrid(clean), clean.prefix(4) != excludingGrid.prefix(4) {
                found.grid = clean
            }
            if found.name == nil, ["NAME", "OP"].contains(clean), index + 1 < words.count {
                let next = words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if next.allSatisfy(\.isLetter), !skipWords.contains(next), !looksLikeCallsign(next) {
                    found.name = next.capitalized
                }
            }
        }
        found.exchange = exchange(in: words)
        return found
    }

    /// Four or six character Maidenhead locator.
    static func isGrid(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count == 4 || chars.count == 6 else { return false }
        guard ("A"..."R").contains(chars[0]), ("A"..."R").contains(chars[1]),
              chars[2].isNumber, chars[3].isNumber else { return false }
        if chars.count == 6 {
            guard ("A"..."X").contains(chars[4]), ("A"..."X").contains(chars[5]) else { return false }
        }
        return true
    }

    /// The exchange, in the forms the mode's grammar renders and the
    /// forms people type: `599 123`, `599 CA`, `599 05 NWT`, `599 FN42`,
    /// `1D EMA`, `-12`, `UR -07`, `R-12 DB`.
    static func exchange(in words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            if word == "599" || word == "5NN" {
                var parts = ["599"]
                var next = index + 1
                while next < words.count, parts.count < 3 {
                    let w = words[next]
                    // A zone then a location, or just the one field.
                    if parts.count == 2, !(isZone(parts[1]) && isBase36(w)) { break }
                    guard isBase36(w) else { break }
                    parts.append(w)
                    next += 1
                }
                if parts.count > 1 { return parts.joined(separator: " ") }
            }
            if let section = classSection(word, words.count > index + 1 ? words[index + 1] : "") {
                return section
            }
        }
        // A decibel report: a signed one or two digit number, optionally
        // tagged R, UR or DB.
        for (index, word) in words.enumerated() {
            var token = word
            if token.hasPrefix("R"), token.count > 1, token.dropFirst().first.map({ $0 == "-" || $0 == "+" }) == true {
                token = String(token.dropFirst())
            }
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            let digits = token.dropFirst()
            guard (1...2).contains(digits.count), digits.allSatisfy(\.isNumber) else { continue }
            _ = index
            return "\(token) dB"
        }
        return nil
    }

    static func isZone(_ word: String) -> Bool {
        guard let value = Int(word) else { return false }
        return (1...90).contains(value)
    }

    static func isBase36(_ word: String) -> Bool {
        !word.isEmpty && word.count <= 6 && word.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
    }

    static func classSection(_ first: String, _ second: String) -> String? {
        guard first.count >= 2, first.count <= 3, let letter = first.last, ("A"..."F").contains(letter),
              let count = Int(first.dropLast()), (1...32).contains(count),
              JTTYAtom.classSection(count: count, classLetter: letter, section: second).isValid else { return nil }
        return "\(first) \(second)"
    }
}
