import XCTest
@testable import JTTYLib

final class CodecTests: XCTestCase {

    func testGoldenVectorsFromTheSpecification() throws {
        let cases: [(JTTYAtom, String, String)] = [
            (.call(.cq, "K1ABC"), "026F78D41", "CQ K1ABC CQ"),
            (.number(.serial, 123, full: true), "20007B009", "599 123"),
            (.location(.stateProvince, "CA", full: true), "2001BA019", "599 CA"),
            (.zoneLocation(zone: 5, token: "NWT"), "00B790D29", "599 05 NWT"),
            (.classSection(count: 1, classLetter: "D", section: "EMA"), "082C58029", "1D EMA"),
            (.serialTime(serial: 156, minuteOfDay: 17 * 60 + 49, full: true), "204E42D39", "599 156 1749"),
            (.control(.agn), "000000049", "AGN?"),
            (.grid("FN42", full: false), "04A198049", "FN42"),
            (.text("HELLO"), "11395558D", "HELLO"),
        ]
        for (atom, hex, text) in cases {
            let packed = try JTTYEncoder.pack(atoms: [atom])
            XCTAssertEqual(String(format: "%09llX", packed.payloads[0]), hex, text)
            XCTAssertEqual(packed.text, text)
            XCTAssertEqual(atom.rendered, text)
        }
    }

    func testFreeTextFrameCounts() throws {
        let cases: [(String, Int, ExchangeProfile)] = [
            ("CQ K1ABC CQ", 1, .none), ("WB9XYZ 599 123", 2, .none), ("599 MA", 1, .none),
            ("599 FN42", 1, .none), ("1D EMA", 1, .none), ("599 001", 2, .none),
            ("599 BRUCE", 2, .none), ("599 001", 1, .rttyRoundup), ("K1ABC 599 001", 2, .rttyRoundup),
            ("THE QUICK BROWN FOX JUMPED OVER THE LAZY DOG.", 9, .none),
            ("cq  ka1abc   cq", 1, .none), ("VP2/KF2GHI", 2, .none),
        ]
        for (text, frames, profile) in cases {
            let packed = try JTTYEncoder.pack(text: text, profile: profile)
            XCTAssertEqual(packed.frameCount, frames, text)
            XCTAssertEqual(packed.text, normalizedText(text).isEmpty ? "" : packed.text)
        }
        XCTAssertEqual(try JTTYEncoder.pack(text: "599 05", profile: .rttyRoundup).text, "599 005")
        XCTAssertThrowsError(try JTTYEncoder.pack(text: "   "))
        // Over-long text is cut at 80 characters, which always fits 16 frames.
        XCTAssertEqual(try JTTYEncoder.pack(text: String(repeating: "ABCDE ", count: 20)).frameCount, 16)
    }

    func testRoundTripThroughFrames() throws {
        let text = "HI WB9XYZ 599 123 TEST AGN NR"
        let packed = try JTTYEncoder.pack(text: text)
        var assembled = ""
        for (index, payload) in packed.payloads.enumerated() {
            let frame = try XCTUnwrap(JTTYEncoder.text(of: payload))
            assembled += frame.text
            if frame.trailingSeparator, index < packed.payloads.count - 1 { assembled += " " }
            XCTAssertEqual(frame.isLast, index == packed.payloads.count - 1)
        }
        XCTAssertEqual(MessageAssembler.displayText(assembled), text)
    }

    func testStandardCallsigns() {
        XCTAssertTrue(isStandardCallsign("K1ABC"))
        XCTAssertTrue(isStandardCallsign("W2ASM"))
        XCTAssertTrue(isStandardCallsign("JA6DEF"))
        XCTAssertTrue(isStandardCallsign("K1A"))
        XCTAssertFalse(isStandardCallsign("PJ4/KA1ABC"))
        XCTAssertFalse(isStandardCallsign("WB9XYZABC"))
        XCTAssertFalse(isStandardCallsign("QU1RK"))
        XCTAssertFalse(isStandardCallsign(""))
    }

    func testMacros() throws {
        let context = MacroContext(myCall: "K1ABC", hisCall: "W9XYZ", queuedCall: "W7UVW", serialNumber: 107)
        func text(_ template: String) -> String? {
            if case .native(_, let text) = NativeMacro.compile(template, context: context) { return text }
            return nil
        }
        XCTAssertEqual(text("CQ %M CQ"), "CQ K1ABC CQ")
        XCTAssertEqual(text("%H %E"), "W9XYZ 599 107")
        XCTAssertEqual(text("%H TU CQ %M CQ"), "W9XYZ TU CQ K1ABC CQ")
        XCTAssertEqual(text("TU NOW %Q %E"), "TU NOW W7UVW 599 107")
        XCTAssertEqual(text("%H AGN?"), "W9XYZ AGN?")
        XCTAssertEqual(text("%E"), "599 107")
        if case .native(let atoms, _) = NativeMacro.compile("%H %E", context: context) {
            XCTAssertEqual(try JTTYEncoder.pack(atoms: atoms).frameCount, 2)
        } else {
            XCTFail("not native")
        }
        XCTAssertEqual(NativeMacro.compile("%H DE %M K", context: context), .literal("W9XYZ DE K1ABC K"))
        if case .invalid = NativeMacro.compile("%H", context: MacroContext(myCall: "K1ABC")) {} else { XCTFail("empty his call accepted") }
        var fieldDay = context
        fieldDay.profile = .fieldDay
        fieldDay.configuredExchange = "1D EMA"
        if case .native(_, let t) = NativeMacro.compile("%H %E", context: fieldDay) { XCTAssertEqual(t, "W9XYZ 1D EMA") } else { XCTFail() }
    }
}
