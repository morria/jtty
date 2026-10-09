import Foundation
import JTTYLib

/// Writes the 12 kHz receiver audio to a WAV file in Documents, so a session
/// that did not decode can be looked at afterwards on a Mac. 16-bit mono;
/// 24 kB per second.
final class AudioRecorder {
    private(set) var url: URL?
    private var handle: FileHandle?
    private var sampleCount = 0

    var isRecording: Bool { handle != nil }
    var duration: TimeInterval { Double(sampleCount) / JTTYProtocol.sampleRate }

    func start() throws {
        stop()
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMdd_HHmmss"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("jtty_\(formatter.string(from: Date())).wav")
        try Self.header(samples: 0).write(to: url)
        handle = try FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        self.url = url
        sampleCount = 0
    }

    func append(_ samples: [Float]) {
        guard let handle else { return }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-32768, min(32767, (sample * 32767).rounded())))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        sampleCount += samples.count
    }

    func stop() {
        guard let handle else { return }
        handle.seek(toFileOffset: 0)
        handle.write(Self.header(samples: sampleCount))
        try? handle.close()
        self.handle = nil
    }

    private static func header(samples: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(JTTYProtocol.sampleRate)
        let bytes = UInt32(samples * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        return data
    }
}
