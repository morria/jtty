import Foundation

/// One frame as the receiver found it.
public struct DecodedFrame: Equatable, Sendable {
    public var payload: UInt64
    /// Tone 0, Hz.
    public var frequency: Float
    /// Start of the frame, seconds from the start of the session.
    public var syncTime: Double
    /// dB in 2500 Hz.
    public var snr: Float
    public var channel: Int
    public var syncMatches: Int
    /// Text with text-frame spaces shown as `~`.
    public var text: String
    public var trailingSeparator: Bool
    public var isLastFrame: Bool

    public init(payload: UInt64, frequency: Float, syncTime: Double, snr: Float, channel: Int = 0,
                syncMatches: Int = 13, text: String, trailingSeparator: Bool, isLastFrame: Bool) {
        self.payload = payload
        self.frequency = frequency
        self.syncTime = syncTime
        self.snr = snr
        self.channel = channel
        self.syncMatches = syncMatches
        self.text = text
        self.trailingSeparator = trailingSeparator
        self.isLastFrame = isLastFrame
    }
}

/// A message growing as its frames arrive.
public struct MessageUpdate: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var frequency: Float
    /// Start of the first frame, seconds from the start of the session.
    public var startTime: Double
    /// Time of the latest frame.
    public var latestTime: Double
    /// Display text: gaps shown as ` ... `.
    public var text: String
    /// Best SNR among the frames so far.
    public var snr: Float
    /// Whether the sender's end-of-message flag has been seen.
    public var isComplete: Bool
    /// How many frames have gone into this message.
    public var frameCount: Int
}

/// Joins frames into messages.
///
/// A transmission is one to sixteen frames exactly one frame period apart on
/// one frequency, and only the last frame says so. So a frame that lands a
/// whole number of periods after the previous frame of an active message,
/// close to its frequency, continues it; a missed frame leaves a gap marker;
/// a message nobody continues for three periods is given up on and shown
/// as it stands.
public struct MessageAssembler: Sendable {

    struct ActiveMessage {
        var id: Int64
        var frequency: Float
        var syncTime: Double
        var startTime: Double
        var decoded: String
        var trailingSeparator: Bool
        var snr: Float
        var frameCount: Int
    }

    struct Fingerprint {
        var frequency: Float
        var syncTime: Double
    }

    static let maxActive = 30
    static let maxRecent = maxActive * JTTYProtocol.maxFrames
    static let maxContinuationGap = 3
    static let maxRetroSteps = 3
    static let historyTimeTolerance = 0.05
    static let historyFrequencyTolerance: Float = 3
    static let nearSimultaneousFrequencyTolerance: Float = 12
    static let continuationTimeTolerance = 0.1
    static let framePeriod = JTTYProtocol.frameDuration

    var active: [ActiveMessage] = []
    var recent: [Fingerprint] = []
    var nextID: Int64 = 1

    public init() {}

    /// Where the next frames of messages in progress are expected.
    public var continuations: [(frequency: Float, syncTime: Double)] {
        active.map { ($0.frequency, $0.syncTime) }
    }

    public mutating func reset() {
        active.removeAll()
        recent.removeAll()
    }

    /// Forget old frames and flush messages whose continuation never came.
    /// Called with the start time of each forward window.
    public mutating func prune(forwardTime: Double) -> [MessageUpdate] {
        let oldestRevisit = forwardTime - Double(Self.maxRetroSteps) * Self.framePeriod / 4
        recent.removeAll { $0.syncTime < oldestRevisit - Self.historyTimeTolerance }
        var updates: [MessageUpdate] = []
        active.removeAll { message in
            let stale = oldestRevisit - message.syncTime >
                Double(Self.maxContinuationGap) * Self.framePeriod + Self.continuationTimeTolerance
            if stale { updates.append(Self.update(for: message, complete: false)) }
            return stale
        }
        return updates
    }

    /// Take in one decoded frame. Returns the update it produced, if any.
    public mutating func ingest(_ frame: DecodedFrame) -> MessageUpdate? {
        if isRecent(frame) { return nil }

        var windowDupe = false
        var best: Int?
        var bestDelta: Float = .greatestFiniteMagnitude
        var bestGap = 1
        for (index, message) in active.enumerated() {
            let (match, isWindowDupe, gap) = Self.classify(message, frame)
            guard match else { continue }
            if isWindowDupe {
                windowDupe = true
                continue
            }
            let delta = abs(frame.frequency - message.frequency)
            if delta < bestDelta {
                bestDelta = delta
                best = index
                bestGap = gap
            }
        }
        if windowDupe { return nil }
        if let best {
            return append(to: best, frame, gap: bestGap)
        }
        return start(frame)
    }

    // MARK: - Internals

    private func isRecent(_ frame: DecodedFrame) -> Bool {
        recent.contains {
            abs($0.frequency - frame.frequency) < Self.nearSimultaneousFrequencyTolerance &&
                abs($0.syncTime - frame.syncTime) < Self.historyTimeTolerance
        }
    }

    private mutating func remember(_ frame: DecodedFrame) {
        if recent.count >= Self.maxRecent { recent.removeFirst() }
        recent.append(Fingerprint(frequency: frame.frequency, syncTime: frame.syncTime))
    }

    /// Whether a frame continues an active message, and by how many periods.
    static func classify(_ existing: ActiveMessage, _ frame: DecodedFrame) -> (match: Bool, windowDupe: Bool, gap: Int) {
        let df = frame.frequency - existing.frequency
        let dt = frame.syncTime - existing.syncTime
        let periods = Int((dt / framePeriod).rounded())
        let residual = abs(dt - framePeriod * Double(periods))
        if periods >= 1, periods <= maxContinuationGap, residual < continuationTimeTolerance {
            let tolerance = 10 + 3 * Float(periods - 1)
            if abs(df) < tolerance { return (true, false, periods) }
        }
        // A retro sweep revisits the three previous quarter-frame windows and
        // can find the same frame again at a slightly different offset.
        let quarter = framePeriod / 4
        let steps = Int((dt / quarter).rounded())
        let stepResidual = abs(dt - quarter * Double(steps))
        if abs(steps) <= maxRetroSteps, abs(df) < 10, stepResidual < 0.003,
           !(abs(steps) % 4 == 0 && steps != 0) {
            return (true, true, 1)
        }
        return (false, false, 1)
    }

    private mutating func start(_ frame: DecodedFrame) -> MessageUpdate? {
        if !frame.isLastFrame, active.count >= Self.maxActive { return nil }
        remember(frame)
        var decoded = frame.text
        if decoded.hasPrefix("599 ") { decoded = "~" + decoded }
        let message = ActiveMessage(
            id: nextID, frequency: frame.frequency, syncTime: frame.syncTime, startTime: frame.syncTime,
            decoded: decoded, trailingSeparator: frame.trailingSeparator, snr: frame.snr, frameCount: 1
        )
        nextID += 1
        if !frame.isLastFrame { active.append(message) }
        return Self.update(for: message, complete: frame.isLastFrame)
    }

    private mutating func append(to index: Int, _ frame: DecodedFrame, gap: Int) -> MessageUpdate? {
        remember(frame)
        var message = active[index]
        let limit = JTTYProtocol.maxTextLength
        if gap > 1 {
            // Frames went missing: mark the hole, then the new text.
            var text = Substring(frame.text)
            if text.first == "~" { text = text.dropFirst() }
            let room = max(limit - message.decoded.count - 5, 0)
            message.decoded += "~~~~~" + text.prefix(room)
        } else {
            let separator = message.trailingSeparator ? " " : ""
            let room = max(limit - message.decoded.count - separator.count, 0)
            message.decoded += separator + frame.text.prefix(room)
        }
        message.trailingSeparator = frame.trailingSeparator
        message.frequency = frame.frequency
        message.syncTime = frame.syncTime
        message.snr = max(message.snr, frame.snr)
        message.frameCount += 1
        if frame.isLastFrame {
            active.remove(at: index)
        } else {
            active[index] = message
        }
        return Self.update(for: message, complete: frame.isLastFrame)
    }

    static func update(for message: ActiveMessage, complete: Bool) -> MessageUpdate {
        MessageUpdate(
            id: message.id, frequency: message.frequency, startTime: message.startTime,
            latestTime: message.syncTime, text: displayText(message.decoded), snr: message.snr,
            isComplete: complete, frameCount: message.frameCount
        )
    }

    /// Receiver markup to text: a five-character gap becomes ` ... `, text
    /// frame spaces become spaces, and the separator a `599` message is
    /// started with is dropped.
    public static func displayText(_ decoded: String) -> String {
        var text = decoded.replacingOccurrences(of: "~~~~~", with: " ... ")
        text = text.replacingOccurrences(of: "~", with: " ")
        if text.hasPrefix(" ") { text.removeFirst() }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
