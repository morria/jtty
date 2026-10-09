import CJTTY
import Foundation

/// A band to look for signals in, besides the receive frequency.
public struct SearchChannel: Equatable, Sendable {
    public var centre: Double
    public var halfWidth: Double
    public init(centre: Double, halfWidth: Double) {
        self.centre = centre
        self.halfWidth = halfWidth
    }

    /// WSJT-X's two fixed channels around the JTTY calling area.
    public static let standard = [SearchChannel(centre: 1350, halfWidth: 150), SearchChannel(centre: 1650, halfWidth: 150)]

    /// The whole audio passband in 300 Hz pieces.
    public static let wide: [SearchChannel] = stride(from: 350.0, to: 2800, by: 300).map {
        SearchChannel(centre: $0, halfWidth: 150)
    }
}

public struct ReceiverSettings: Equatable, Sendable {
    /// Where the operator is listening, Hz, and how far either side.
    public var rxFrequency: Double = 1500
    public var rxTolerance: Double = 100
    public var extraChannels: [SearchChannel] = SearchChannel.wide
    public var minFrequency: Double = 200
    public var maxFrequency: Double = 2800
    public init() {}
}

/// The streaming receiver: feed it 12 kHz mono audio and it hands back
/// messages as they build up.
///
/// Not thread safe: use it from one queue. Decoding happens inside
/// `append`, which returns quickly when there is not yet a whole window to
/// look at and otherwise spends a few tens of milliseconds per window.
public final class JTTYReceiver {

    public enum Event: Equatable, Sendable {
        case frame(DecodedFrame)
        case message(MessageUpdate)
    }

    public var settings = ReceiverSettings()

    /// Running totals for the session.
    public struct Statistics: Equatable, Sendable {
        /// Peaks on the sync surface that were examined.
        public var candidates = 0
        /// Peaks whose sync tones checked out: JTTY-shaped signals.
        public var syncHits = 0
        /// Frames the FEC accepted and the grammar passed.
        public var decodes = 0
        public init() {}
    }
    public private(set) var statistics = Statistics()

    private let receiver: OpaquePointer
    private var buffer: [Float] = []
    /// Session sample index of `buffer[0]`.
    private var base = 0
    /// Session sample index of the next window to decode.
    private var nextWindow = 0
    private var assembler = MessageAssembler()
    private var decodes = [jtty_decode](repeating: jtty_decode(), count: 64)

    public init() {
        receiver = jtty_receiver_create()
    }

    deinit {
        jtty_receiver_destroy(receiver)
    }

    /// Seconds of audio taken in so far.
    public var elapsed: TimeInterval { Double(base + buffer.count) / JTTYProtocol.sampleRate }

    public func reset() {
        buffer.removeAll()
        base = 0
        nextWindow = 0
        assembler.reset()
        statistics = Statistics()
    }

    /// Add audio. Returns everything decoded as a result, in order.
    @discardableResult
    public func append(_ samples: [Float]) -> [Event] {
        buffer.append(contentsOf: samples)
        var events: [Event] = []
        let chunk = JTTYProtocol.chunkSamples
        let step = JTTYProtocol.stepSamples
        while nextWindow + chunk <= base + buffer.count {
            events.append(contentsOf: decodeWindow(at: nextWindow))
            nextWindow += step
        }
        // Keep only what the retro sweeps can still reach.
        let keepFrom = nextWindow - MessageAssembler.maxRetroSteps * step
        if keepFrom > base {
            let drop = min(keepFrom - base, buffer.count)
            buffer.removeFirst(drop)
            base += drop
        }
        return events
    }

    /// Decode one window, then re-sweep the three windows before it with
    /// each newly found signal taken out.
    private func decodeWindow(at start: Int) -> [Event] {
        var events: [Event] = []
        for update in assembler.prune(forwardTime: seconds(start)) {
            events.append(.message(update))
        }
        let found = process(window: start, known: nil)
        for frame in found {
            events.append(.frame(frame))
            if let update = assembler.ingest(frame) { events.append(.message(update)) }
        }
        let step = JTTYProtocol.stepSamples
        for frame in found {
            for k in 1...MessageAssembler.maxRetroSteps {
                let previous = start - k * step
                guard previous >= base else { continue }
                let known = jtty_known_signal(frequency: frame.frequency, sync_time: Float(frame.syncTime), payload: frame.payload)
                for retro in process(window: previous, known: known) {
                    events.append(.frame(retro))
                    if let update = assembler.ingest(retro) { events.append(.message(update)) }
                }
            }
        }
        return events
    }

    private func seconds(_ sample: Int) -> Double {
        Double(sample) / JTTYProtocol.sampleRate
    }

    private func process(window start: Int, known: jtty_known_signal?) -> [DecodedFrame] {
        let offset = start - base
        guard offset >= 0, offset + JTTYProtocol.chunkSamples <= buffer.count else { return [] }
        let channels = settings.extraChannels.map { jtty_channel(centre: Float($0.centre), half_width: Float($0.halfWidth)) }
        let hints = assembler.continuations.map { jtty_continuation(frequency: $0.frequency, sync_time: Float($0.syncTime)) }
        var knownCopy = known
        var count: Int32 = 0
        buffer.withUnsafeBufferPointer { samples in
            channels.withUnsafeBufferPointer { channelPointer in
                hints.withUnsafeBufferPointer { hintPointer in
                    withUnsafePointer(to: &knownCopy) { knownPointer in
                        var request = jtty_receive_request()
                        request.rx_frequency = Float(settings.rxFrequency)
                        request.rx_tolerance = Float(settings.rxTolerance)
                        request.extra_channels = channelPointer.baseAddress
                        request.extra_channel_count = Int32(channelPointer.count)
                        request.min_frequency = Float(settings.minFrequency)
                        request.max_frequency = Float(settings.maxFrequency)
                        request.continuations = hintPointer.baseAddress
                        request.continuation_count = Int32(hintPointer.count)
                        request.known = known == nil ? nil : UnsafePointer(knownPointer.withMemoryRebound(to: jtty_known_signal.self, capacity: 1) { $0 })
                        request.window_start = seconds(start)
                        count = jtty_receiver_process(receiver, samples.baseAddress! + offset, &request, &decodes, Int32(decodes.count))
                    }
                }
            }
        }
        let stats = jtty_receiver_last_stats(receiver)
        statistics.candidates += Int(stats.candidates)
        statistics.syncHits += Int(stats.sync_hits)
        statistics.decodes += Int(stats.decodes)
        return (0..<Int(count)).map { Self.frame(from: decodes[$0]) }
    }

    static func frame(from d: jtty_decode) -> DecodedFrame {
        var text = d.text
        let string = withUnsafePointer(to: &text) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return DecodedFrame(
            payload: d.payload, frequency: d.frequency, syncTime: Double(d.sync_time), snr: d.snr,
            channel: Int(d.channel), syncMatches: Int(d.sync_matches), text: string,
            trailingSeparator: d.trailing_sep, isLastFrame: d.eom
        )
    }
}
