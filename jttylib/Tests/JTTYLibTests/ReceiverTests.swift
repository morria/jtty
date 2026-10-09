import XCTest
@testable import JTTYLib

final class ReceiverTests: XCTestCase {

    /// The off-air sample that ships with WSJT-X, fed in 40 ms buffers the
    /// way the audio tap delivers them.
    func testDecodesTheShippedSample() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "260807_134110", withExtension: "wav", subdirectory: "Resources"))
        let data = try Data(contentsOf: url)
        let samples: [Float] = data.dropFirst(44).withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            return int16.map { Float($0) / 32768 }
        }
        let receiver = JTTYReceiver()
        receiver.settings.rxFrequency = 1500
        receiver.settings.rxTolerance = 100
        var messages: [Int64: MessageUpdate] = [:]
        var frames = 0
        for start in stride(from: 0, to: samples.count, by: 480) {
            for event in receiver.append(Array(samples[start..<min(start + 480, samples.count)])) {
                switch event {
                case .frame: frames += 1
                case .message(let update): messages[update.id] = update
                }
            }
        }
        XCTAssertEqual(frames, 10)
        let complete = messages.values.filter(\.isComplete)
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete.first?.text, "RAN ALL NIGHT ON BAND NOISE - NO FALSE DECODES!")
        XCTAssertEqual(complete.first?.frameCount, 10)
        XCTAssertEqual(Double(complete.first?.frequency ?? 0), 1507, accuracy: 2)
    }

    /// Modulate, add noise, decode: two messages at once on different
    /// frequencies, which exercises subtraction and the assembler.
    func testLoopbackWithTwoStations() throws {
        let a = JTTYTransmission(message: try JTTYEncoder.pack(text: "CQ K1ABC CQ"), frequency: 1500, gain: 0.3)
        let b = JTTYTransmission(message: try JTTYEncoder.pack(text: "W9XYZ 599 107"), frequency: 1740, gain: 0.05)
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Float {
            let u1 = Float.random(in: Float.leastNonzeroMagnitude..<1, using: &rng)
            let u2 = Float.random(in: 0..<1, using: &rng)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let total = 12000 * 12
        var audio = (0..<total).map { _ in 0.02 * gauss() }
        for (i, s) in a.samples.enumerated() { audio[12000 * 2 + i] += s }
        for (i, s) in b.samples.enumerated() { audio[12000 * 2 + 3000 + i] += s }
        let receiver = JTTYReceiver()
        receiver.settings.extraChannels = SearchChannel.wide
        var texts: Set<String> = []
        for start in stride(from: 0, to: total, by: 480) {
            for case .message(let update) in receiver.append(Array(audio[start..<min(start + 480, total)])) where update.isComplete {
                texts.insert(update.text)
            }
        }
        XCTAssertEqual(texts, ["CQ K1ABC CQ", "W9XYZ 599 107"])
    }

    func testAssemblerJoinsFramesAndMarksGaps() {
        var assembler = MessageAssembler()
        func frame(_ text: String, at t: Double, sep: Bool, last: Bool) -> DecodedFrame {
            DecodedFrame(payload: 1, frequency: 1500, syncTime: t, snr: -5, text: text, trailingSeparator: sep, isLastFrame: last)
        }
        let period = JTTYProtocol.frameDuration
        XCTAssertEqual(assembler.ingest(frame("W9XYZ", at: 10, sep: true, last: false))?.text, "W9XYZ")
        XCTAssertEqual(assembler.ingest(frame("599 107", at: 10 + period, sep: true, last: false))?.text, "W9XYZ 599 107")
        // One frame missed, then text.
        let gap = assembler.ingest(frame("HELLO", at: 10 + 3 * period, sep: false, last: true))
        XCTAssertEqual(gap?.text, "W9XYZ 599 107 ... HELLO")
        XCTAssertEqual(gap?.isComplete, true)
        XCTAssertTrue(assembler.continuations.isEmpty)
        // The same frame seen again from a retro sweep is not a new message.
        XCTAssertNil(assembler.ingest(frame("W9XYZ", at: 10.01, sep: true, last: false)))
    }
}
