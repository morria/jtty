import Foundation
import JTTYLib
import OSLog
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "com.w2asm.jtty", category: "model")

/// One line of the transcript: a message heard, or one sent.
struct TranscriptLine: Identifiable, Equatable {
    enum Kind: Equatable { case received, sent }
    var id: Int64
    var kind: Kind
    var text: String
    /// Tone 0, Hz.
    var frequency: Double
    var snr: Float?
    var time: Date
    /// Still arriving (received) or still going out (sent).
    var isInProgress: Bool
    var frameCount: Int
    /// Whether the message came in near the receive frequency.
    var isOnFrequency: Bool
    /// For a sent message: the receiver heard it back through the radio's
    /// monitor, which is the proof it went out. The SNR is the echo's.
    var heardBack = false

    /// The first thing in the message that looks like a callsign, compound
    /// and portable calls included.
    var callsign: String? {
        let skip: Set<String> = ["CQ", "TU", "NOW", "AGN?", "DE", "QRZ?", "599", "DX", "TEST"]
        for word in text.split(separator: " ").map(String.init) where !skip.contains(word) && looksLikeCallsign(word) {
            return word
        }
        return nil
    }
}

@MainActor
@Observable
final class AppModel {
    var preferences: Preferences {
        didSet {
            if !suppressesSaving { preferences.save() }
            applyPreferences()
        }
    }
    /// Debug modes seed settings that must not survive the launch.
    private var suppressesSaving = false
    let audio = RadioAudioController()
    let logbook = Logbook()
    /// Which tab is showing; set to move the operator to Settings.
    var selectedTab = 0
    /// The one-time offer to upload contacts to QRZ.
    var offersQRZ = false

    private(set) var transcript: [TranscriptLine] = []
    /// What the receiver has looked at this session.
    private(set) var statistics = JTTYReceiver.Statistics()
    /// Recent spectrum, for choosing a clear frequency. Not observed: the
    /// screen reads the rendered waterfall instead, so ten updates a second
    /// here do not redraw the transcript.
    @ObservationIgnored private(set) var spectrumLines: [RadioAudioController.SpectrumLine] = []
    static let spectrumHistory = 90
    let waterfall = WaterfallRenderer()

    /// The station being worked and the one waiting.
    var theirCall = ""
    var queuedCall = ""

    /// The frequency of the conversation on screen, if one is open. A
    /// conversation is everything within `conversationHalfWidth` of it: a
    /// JTTY contact is worked on one frequency, and 60 Hz either side is
    /// well inside one signal's width while staying clear of the next
    /// channel over.
    var activeConversation: Double?
    static let conversationHalfWidth: Double = 60
    /// Whether the app is on screen. Off screen, a message for us becomes
    /// a notification instead of a haptic.
    var isForeground = true
    /// When each conversation was last read, by frequency. Matched within
    /// the conversation half width, since a conversation drifts a few hertz.
    private var lastRead: [Double: Date] = [:]
    /// Bumped each time a complete message addressed to us arrives, for a
    /// haptic. The count itself means nothing.
    private(set) var repliesToMe = 0
    /// Received lines already announced, so a message is announced once.
    private var announced: Set<Int64> = []
    /// Conversations opened by hand that have no traffic yet still need a row.
    private(set) var emptyConversations: [Double] = []

    /// A transmission waiting on the band being confirmed.
    private var pendingSend: (() -> Void)?
    var isConfirmingBand = false

    var errorMessage: String?
    private var nextSentID: Int64 = -1
    /// Sent lines by id, in order queued, so the one playing can be marked done.
    private var pendingSent: [Int64] = []

    init() {
        preferences = Preferences.load()
        applyPreferences()
        audio.onEvents = { [weak self] events, start in self?.handle(events, sessionStart: start) }
        audio.onSpectrum = { [weak self] line in self?.handle(line) }
        audio.onStatistics = { [weak self] stats in self?.statistics = stats }
        audio.onTransmitFinished = { [weak self] in self?.transmissionsFinished() }
        #if DEBUG
        if CommandLine.arguments.contains("-demo") { seedDemo() }
        if CommandLine.arguments.contains("-selftest") { runSelfTest() }
        #endif
    }

    #if DEBUG
    /// Start the audio, send F1 and F2, and write what happened to
    /// Documents/selftest.log, so the real audio path can be checked on a
    /// phone from the command line. Nothing is persisted.
    private func runSelfTest() {
        suppressesSaving = true
        var prefs = preferences
        if prefs.callsign.isEmpty { prefs.callsign = "W2ASM" }
        prefs.hasCompletedSetup = true
        preferences = prefs
        theirCall = "W9XYZ"
        prefs.lastTransmitAt = Date()
        preferences = prefs
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.log")
        var lines: [String] = []
        func note(_ text: String) {
            lines.append("\(Date().formatted(.iso8601)) \(text)")
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
        note("self-test started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            toggleListening()
            note("listening=\(isListening) error=\(errorMessage ?? "none")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                sendMacro(0)
                sendMacro(1)
                note("sent F1+F2 transmitting=\(isTransmitting) queued=\(audio.queuedTransmissions) error=\(errorMessage ?? "none") level=\(audio.inputLevel)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self else { return }
                    note("after 8 s transmitting=\(isTransmitting) queued=\(audio.queuedTransmissions) level=\(audio.inputLevel) heard=\(transcript.filter { $0.kind == .received }.count) sentDone=\(transcript.filter { $0.kind == .sent && !$0.isInProgress }.count)")
                    toggleListening()
                    note("stopped listening=\(isListening)")
                }
            }
        }
    }

    /// A screen's worth of made-up traffic, for checking the layout on a
    /// simulator that has no radio behind it.
    private func seedDemo() {
        suppressesSaving = true
        var prefs = preferences
        prefs.callsign = "W2ASM"
        prefs.grid = "FN20"
        prefs.hasCompletedSetup = true
        prefs.serialNumber = 107
        prefs.lastTransmitAt = Date()
        prefs.contestMode = CommandLine.arguments.contains("-contest")
        preferences = prefs
        theirCall = "W9XYZ"
        let now = Date()
        if logbook.entries.isEmpty, CommandLine.arguments.contains("-demolog") {
            logbook.add(LogEntry(callsign: "K1ABC", time: now.addingTimeInterval(-900), band: .m20, frequency: 14_081_500,
                                 exchangeSent: "599 105", exchangeReceived: "599 212", myCallsign: "W2ASM", myGrid: "FN20"))
            logbook.add(LogEntry(callsign: "W1UE", time: now.addingTimeInterval(-300), band: .m20, frequency: 14_081_500,
                                 exchangeSent: "599 106", exchangeReceived: "599 034", myCallsign: "W2ASM", myGrid: "FN20"))
        }
        let lines: [(String, Double, Float, Int, Bool, TranscriptLine.Kind)] = [
            ("CQ K1ABC CQ", 1507, -3, 1, false, .received),
            ("CQ NA5M EM11", 2210, -14, 2, false, .received),
            ("RAN ALL NIGHT ON BAND NOISE - NO FALSE DECODES!", 1507, -9, 10, false, .received),
            ("CQ W1UE CQ", 820, -11, 1, false, .received),
            ("CQ W2ASM CQ", 1500, 0, 1, false, .sent),
            ("K1ABC AGN?", 820, -6, 1, false, .received),
            ("W9XYZ", 1502, 4, 1, false, .received),
            ("W9XYZ 599 107", 1500, 0, 2, false, .sent),
            ("NA5M FN30AQ", 2210, 17, 3, false, .sent),
            ("599 0", 1502, 5, 1, true, .received),
        ]
        for (index, line) in lines.enumerated() {
            let heard = line.5 == .sent && line.2 != 0
            transcript.append(TranscriptLine(
                id: Int64(1000 + index), kind: line.5, text: line.0, frequency: line.1,
                snr: line.5 == .sent && !heard ? nil : line.2, time: now.addingTimeInterval(Double(index - lines.count) * 7),
                isInProgress: line.4, frameCount: line.3, isOnFrequency: abs(line.1 - 1500) < 100, heardBack: heard
            ))
        }
        var generator = SystemRandomNumberGenerator()
        let width = Int((2800.0 - 200.0) / (12000.0 / 4096.0))
        for row in 0..<Self.spectrumHistory {
            var magnitudes = (0..<width).map { _ in Float.random(in: -70 ... -62, using: &generator) }
            for (hz, strength) in [(1507.0, 25.0), (1518.0, 12.0), (2210.0, 18.0)] {
                let bin = Int((hz - 200) / (12000.0 / 4096.0))
                let on = (row / 18) % 2 == 0 || hz > 2000
                guard on else { continue }
                for k in 0..<44 where bin + k < width {
                    magnitudes[bin + k] += Float(strength) * Float.random(in: 0.3...1, using: &generator)
                }
            }
            let line = RadioAudioController.SpectrumLine(magnitudes: magnitudes)
            spectrumLines.append(line)
            waterfall.append(line)
        }
    }
    #endif

    // MARK: - Settings

    private func applyPreferences() {
        var settings = ReceiverSettings()
        settings.rxFrequency = preferences.rxFollowsTx ? preferences.txFrequency : preferences.rxFrequency
        settings.rxTolerance = preferences.rxTolerance
        settings.extraChannels = preferences.searchesWholePassband ? SearchChannel.wide : SearchChannel.standard
        audio.settings = settings
    }

    var macroContext: MacroContext {
        MacroContext(
            myCall: preferences.callsign, theirCall: theirCall, queuedCall: queuedCall,
            serialNumber: preferences.serialNumber, grid: preferences.grid,
            profile: preferences.contestMode ? preferences.exchangeProfile : .none,
            configuredExchange: preferences.configuredExchange
        )
    }

    var receiveFrequency: Double {
        preferences.rxFollowsTx ? preferences.txFrequency : preferences.rxFrequency
    }

    // MARK: - Listening

    var isListening: Bool { audio.isRunning }

    func toggleListening() {
        if audio.isRunning {
            audio.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            do {
                statistics = JTTYReceiver.Statistics()
                try audio.start()
                // A contact should not finish behind a locked screen.
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                report(error)
            }
        }
    }

    private func handle(_ events: [JTTYReceiver.Event], sessionStart: Date) {
        for event in events {
            guard case .message(let update) = event else { continue }
            let time = sessionStart.addingTimeInterval(update.startTime)
            if absorbEcho(update, at: time) { continue }
            let onFrequency = abs(Double(update.frequency) - receiveFrequency) < preferences.rxTolerance
            let line = TranscriptLine(
                id: update.id, kind: .received, text: update.text, frequency: Double(update.frequency),
                snr: update.snr, time: time, isInProgress: !update.isComplete, frameCount: update.frameCount,
                isOnFrequency: onFrequency
            )
            if let index = transcript.firstIndex(where: { $0.id == update.id && $0.kind == .received }) {
                transcript[index] = line
            } else {
                transcript.append(line)
            }
            if isForeground, let active = activeConversation, Self.line(line, isNear: active) {
                markRead(near: active)
            }
            if update.isComplete, !announced.contains(line.id), mentionsMe(line.text) {
                announced.insert(line.id)
                repliesToMe += 1
                if !isForeground { notify(line) }
            }
        }
        if transcript.count > 500 { transcript.removeFirst(transcript.count - 500) }
    }

    // MARK: - Read state and replies

    /// Whether a message names our callsign.
    func mentionsMe(_ text: String) -> Bool {
        let mine = preferences.callsign
        guard !mine.isEmpty else { return false }
        return text.uppercased().split(separator: " ").contains { $0 == Substring(mine) || $0.hasSuffix("/" + mine) || $0.hasPrefix(mine + "/") }
    }

    private func lastReadKey(near frequency: Double) -> Double? {
        lastRead.keys.first { abs($0 - frequency) <= Self.conversationHalfWidth }
    }

    /// The conversation at `frequency` has been seen up to now.
    func markRead(near frequency: Double) {
        if let key = lastReadKey(near: frequency) { lastRead.removeValue(forKey: key) }
        lastRead[frequency] = Date()
    }

    /// Messages heard in a conversation since it was last open. The open
    /// conversation, on screen, is always read.
    func unreadCount(in band: FrequencyBand) -> Int {
        if isForeground, let active = activeConversation, abs(active - band.frequency) <= Self.conversationHalfWidth { return 0 }
        let since = lastReadKey(near: band.frequency).flatMap { lastRead[$0] } ?? .distantPast
        return band.lines.filter { $0.kind == .received && $0.time > since }.count
    }

    /// How many conversations have something unread, for the tab badge.
    var unreadConversations: Int {
        bands.filter { unreadCount(in: $0) > 0 }.count
    }

    /// Asked the first time something is sent: that is the first moment a
    /// reply matters. The receiver keeps decoding in the background.
    private func requestNotificationsIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// A message for us, arrived while the app was off screen.
    private func notify(_ line: TranscriptLine) {
        let content = UNMutableNotificationContent()
        content.title = line.callsign ?? "Heard on \(Int(line.frequency)) Hz"
        content.body = line.text
        content.sound = .default
        content.threadIdentifier = "\(Int(line.frequency.rounded()))"
        let request = UNNotificationRequest(identifier: "line-\(line.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Our own transmission coming back through the radio: the same text,
    /// on the transmit frequency, starting within a minute of being sent.
    /// Shown once, as the sent message, marked heard, rather than twice.
    private func absorbEcho(_ update: MessageUpdate, at time: Date) -> Bool {
        guard let index = transcript.lastIndex(where: { line in
            line.kind == .sent &&
                abs(line.frequency - Double(update.frequency)) < 25 &&
                time.timeIntervalSince(line.time) > -3 && time.timeIntervalSince(line.time) < 90 &&
                Self.isEcho(update.text, of: line.text)
        }) else { return false }
        if update.isComplete || Self.normalize(update.text) == Self.normalize(transcript[index].text) {
            transcript[index].heardBack = true
            transcript[index].snr = update.snr
        }
        // An earlier partial of the same echo may have got through as a
        // received line before the text was long enough to match.
        transcript.removeAll { $0.kind == .received && $0.id == update.id }
        return true
    }

    private static func normalize(_ text: String) -> String {
        text.uppercased().split(separator: " ").joined(separator: " ")
    }

    /// Whether what came in is what went out, or the beginning of it while
    /// the rest is still arriving. The first text frame alone is five
    /// characters, so anything shorter than three is not evidence.
    static func isEcho(_ heard: String, of sent: String) -> Bool {
        let h = normalize(heard), s = normalize(sent)
        guard h.count >= 3 else { return false }
        return s == h || s.hasPrefix(h) || s.hasPrefix(h.replacingOccurrences(of: " ... ", with: " "))
    }

    private func handle(_ line: RadioAudioController.SpectrumLine) {
        spectrumLines.append(line)
        if spectrumLines.count > Self.spectrumHistory { spectrumLines.removeFirst() }
        waterfall.append(line)
    }

    func clearTranscript() {
        transcript.removeAll()
        emptyConversations.removeAll()
    }

    // MARK: - Conversations

    /// Whether a line belongs to the conversation on `frequency`.
    static func line(_ line: TranscriptLine, isNear frequency: Double) -> Bool {
        abs(line.frequency - frequency) <= conversationHalfWidth
    }

    func lines(near frequency: Double) -> [TranscriptLine] {
        transcript.filter { Self.line($0, isNear: frequency) }
    }

    /// The conversations on the band, most recent first.
    var bands: [FrequencyBand] {
        FrequencyBand.bands(from: transcript, extra: emptyConversations, halfWidth: Self.conversationHalfWidth)
    }

    /// Open the conversation at a frequency: the transmit frequency moves
    /// onto it, since that is where any reply belongs.
    func enterConversation(at frequency: Double, callsign: String? = nil) {
        activeConversation = frequency
        markRead(near: frequency)
        preferences.txFrequency = frequency
        if !preferences.rxFollowsTx { preferences.rxFrequency = frequency }
        if let callsign, theirCall.isEmpty { theirCall = callsign }
    }

    func leaveConversation() {
        if let active = activeConversation { markRead(near: active) }
        activeConversation = nil
    }

    /// A fresh conversation for calling CQ: on a clear frequency if that is
    /// on, otherwise wherever the transmit frequency is.
    func newConversationFrequency() -> Double {
        if preferences.choosesClearFrequency { chooseClearFrequency() }
        let frequency = preferences.txFrequency
        if !emptyConversations.contains(where: { abs($0 - frequency) <= Self.conversationHalfWidth }) {
            emptyConversations.append(frequency)
        }
        return frequency
    }

    func toggleRecording() {
        do { try audio.toggleRecording() } catch { report(error) }
    }

    /// Hold a steady carrier for ten seconds at the transmit frequency.
    func tune() {
        if !audio.isRunning {
            do { try audio.start() } catch { report(error); return }
        }
        if audio.isTuning {
            audio.stopTransmitting()
        } else {
            audio.tune(frequency: preferences.txFrequency, gain: Float(preferences.txGain))
        }
    }

    // MARK: - Transmitting

    var isTransmitting: Bool { audio.isTransmitting }

    /// Send free text, packed automatically.
    func send(text: String) {
        guard preferences.canTransmit else {
            errorMessage = "Set your callsign in Settings before transmitting."
            return
        }
        do {
            let packed = try JTTYEncoder.pack(text: text, profile: preferences.exchangeProfile)
            send(packed)
        } catch {
            report(error)
        }
    }

    /// Send quick message `index` (0-based).
    func sendMacro(_ index: Int) {
        guard preferences.macros.indices.contains(index) else { return }
        guard preferences.canTransmit else {
            errorMessage = "Set your callsign in Settings before transmitting."
            return
        }
        switch NativeMacro.compile(preferences.macros[index], context: macroContext) {
        case .native(let atoms, _):
            do { send(try JTTYEncoder.pack(atoms: atoms)) } catch { report(error) }
        case .literal(let text):
            send(text: text)
        case .invalid(let why):
            errorMessage = why
        }
    }

    /// The band was confirmed (or changed) in the sheet: carry on.
    func confirmBand() {
        isConfirmingBand = false
        preferences.lastTransmitAt = Date()
        let send = pendingSend
        pendingSend = nil
        send?()
    }

    func cancelBandConfirmation() {
        isConfirmingBand = false
        pendingSend = nil
    }

    /// Pick the quietest spot near the transmit frequency from the last few
    /// seconds of spectrum. Only before a CQ: once a contact is under way
    /// the frequency stays put.
    ///
    /// Quiet is judged against the local noise floor, not in absolute terms.
    /// The radio's audio passband rolls off at its edges, so the edges always
    /// look quietest and an absolute choice walks the station down to 300 Hz
    /// where the filter skirt is. What matters is a slot with nothing in it
    /// above the floor around it, and the search stays within 400 to 2600 Hz.
    func chooseClearFrequency() {
        let recent = spectrumLines.suffix(30)
        guard recent.count >= 10, let width = recent.first?.magnitudes.count else { return }
        let binHz = JTTYProtocol.sampleRate / Double(SpectrumAnalyzer.size)
        let minHz = RadioAudioController.SpectrumLine.minFrequency
        var level = [Float](repeating: 0, count: width)
        for line in recent where line.magnitudes.count == width {
            for i in 0..<width { level[i] += line.magnitudes[i] / Float(recent.count) }
        }
        // Local floor: the median over 400 Hz either side.
        let half = Int(400 / binHz)
        var floor = [Float](repeating: 0, count: width)
        for i in 0..<width {
            let window = level[max(0, i - half)...min(width - 1, i + half)].sorted()
            floor[i] = window[window.count / 2]
        }
        let slot = Int(160 / binHz)
        let tx = preferences.txFrequency
        let low = max(400, tx - 300), high = min(2600, tx + 300)
        var best: (start: Int, excess: Float)?
        var current: Float?
        var start = Int((low - minHz) / binHz)
        let last = Int((high - minHz) / binHz) - slot
        while start <= last, start + slot <= width {
            // Energy above the floor, summed over the slot.
            var excess: Float = 0
            for i in start..<start + slot { excess += pow(10, max(0, level[i] - floor[i]) / 10) - 1 }
            let hz = minHz + Double(start) * binHz
            if abs(hz - tx) < binHz * 2 { current = excess }
            if best == nil || excess < best!.excess { best = (start, excess) }
            start += 2
        }
        guard let best else { return }
        // Already clear: stay put rather than wander.
        if let current, current <= Float(slot) * 0.26 { return }
        let hz = ((minHz + Double(best.start) * binHz + 15) / 10).rounded() * 10
        if abs(hz - tx) >= 20 { preferences.txFrequency = hz }
    }

    /// What a function key would send right now, for its button.
    func preview(ofMacro index: Int) -> String {
        guard preferences.macros.indices.contains(index) else { return "" }
        switch NativeMacro.compile(preferences.macros[index], context: macroContext) {
        case .native(_, let text): return text
        case .literal(let text): return normalizedText(text)
        case .invalid: return preferences.macros[index]
        }
    }

    private func send(_ packed: PackedMessage) {
        // A stale band is the commonest way a contact gets logged wrong, so
        // the first transmission in a while asks.
        if preferences.bandIsStale, !isConfirmingBand {
            pendingSend = { [weak self] in self?.send(packed) }
            isConfirmingBand = true
            return
        }
        if !audio.isRunning {
            do { try audio.start() } catch { report(error); return }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // Calling CQ from the band picks a clear spot; inside a conversation
        // the frequency is the conversation's and stays put.
        if preferences.choosesClearFrequency, theirCall.isEmpty, activeConversation == nil, !audio.isTransmitting {
            chooseClearFrequency()
        }
        let transmission = JTTYTransmission(
            message: packed, frequency: preferences.txFrequency, gain: Float(preferences.txGain)
        )
        guard audio.transmit(transmission) else {
            errorMessage = "Could not start transmitting."
            return
        }
        preferences.lastTransmitAt = Date()
        requestNotificationsIfNeeded()
        let id = nextSentID
        nextSentID -= 1
        pendingSent.append(id)
        transcript.append(TranscriptLine(
            id: id, kind: .sent, text: packed.text, frequency: preferences.txFrequency, snr: nil,
            time: Date(), isInProgress: true, frameCount: packed.frameCount, isOnFrequency: true
        ))
        log.info("tx \(packed.frameCount, privacy: .public) frames: \(packed.text, privacy: .public)")
        noteContestProgress(after: packed.text)
    }

    func stopTransmitting() {
        audio.stopTransmitting()
        transmissionsFinished()
    }

    private func transmissionsFinished() {
        for id in pendingSent {
            if let index = transcript.firstIndex(where: { $0.id == id }) {
                transcript[index].isInProgress = false
            }
        }
        pendingSent.removeAll()
    }

    /// A "TU" message closes a contact: log it and move the serial on, as
    /// WSJT-X does when a message starts with TU.
    private func noteContestProgress(after text: String) {
        let closes = text.hasPrefix("TU ") || text.contains(" TU ") || text.hasSuffix(" TU")
        guard closes, !theirCall.isEmpty, !text.hasPrefix("TU \(preferences.callsign) ") || text.contains(theirCall) else { return }
        logContact()
        if preferences.contestMode, preferences.exchangeProfile != .fieldDay {
            preferences.serialNumber = min(preferences.serialNumber + 1, 131071)
        }
        // TU NOW hands the exchange to the queued station.
        if text.hasPrefix("TU NOW "), !queuedCall.isEmpty {
            theirCall = queuedCall
            queuedCall = ""
        } else {
            theirCall = ""
        }
    }

    // MARK: - Stations

    /// What the transcript knows about a station: where and when it was
    /// last heard, how strong, and the grid if it sent one.
    struct Station: Equatable {
        var callsign: String
        var grid: String
        var lastHeard: TranscriptLine
        var messageCount: Int
    }

    func station(_ callsign: String, near frequency: Double) -> Station? {
        let theirs = lines(near: frequency).filter { $0.kind == .received && $0.callsign == callsign }
        guard let last = theirs.last else { return nil }
        let draft = ContactParser.draft(from: last, conversation: lines(near: frequency), myCallsign: preferences.callsign, myGrid: preferences.grid)
        return Station(callsign: callsign, grid: draft.theirGrid, lastHeard: last, messageCount: theirs.count)
    }

    // MARK: - Contacts

    /// What we sent as the exchange in this contact, if anything.
    private var lastExchangeSent: String {
        guard preferences.contestMode else { return "" }
        if case .native(_, let text) = NativeMacro.exchange(macroContext) { return text }
        return String(format: "599 %03d", preferences.serialNumber)
    }

    /// The most recent exchange heard on frequency that was not ours.
    private var lastExchangeReceived: String {
        for line in transcript.reversed() where line.kind == .received && line.isOnFrequency {
            if let range = line.text.range(of: "599 ") {
                let rest = line.text[range.lowerBound...]
                let words = rest.split(separator: " ").prefix(2)
                if words.count == 2 { return words.joined(separator: " ") }
            }
        }
        return ""
    }

    /// A contact read out of a heard message and the conversation around
    /// it, for the operator to check and save.
    func draftContact(from line: TranscriptLine) -> LogEntry {
        let draft = ContactParser.draft(
            from: line, conversation: lines(near: line.frequency),
            myCallsign: preferences.callsign, myGrid: preferences.grid
        )
        return LogEntry(
            callsign: draft.callsign.isEmpty ? theirCall : draft.callsign,
            time: draft.time, band: preferences.band,
            frequency: preferences.dialFrequency + Int(line.frequency),
            exchangeSent: draft.exchangeSent.isEmpty ? lastExchangeSent : draft.exchangeSent,
            exchangeReceived: draft.exchangeReceived,
            myCallsign: preferences.callsign, myGrid: preferences.grid,
            theirGrid: draft.theirGrid, name: draft.name
        )
    }

    func logContact() {
        let call = theirCall.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return }
        let entry = LogEntry(
            callsign: call, time: Date(), band: preferences.band,
            frequency: preferences.dialFrequency + Int(preferences.txFrequency),
            exchangeSent: lastExchangeSent, exchangeReceived: lastExchangeReceived,
            myCallsign: preferences.callsign, myGrid: preferences.grid
        )
        record(entry)
    }

    /// Put a contact in the log, send it on to QRZ if that is set up, and
    /// the first time, offer to set it up.
    func record(_ entry: LogEntry) {
        logbook.add(entry)
        if preferences.logsToQRZ {
            let uploader = LogUploader(enabled: true)
            Task { await uploader.upload(entry, into: logbook) }
        } else if !preferences.qrzOfferMade {
            preferences.qrzOfferMade = true
            offersQRZ = true
        }
    }

    /// Anything not yet uploaded, retried when the app comes forward.
    func uploadPending() {
        guard preferences.logsToQRZ else { return }
        let uploader = LogUploader(enabled: true)
        Task { await uploader.uploadPending(from: logbook) }
    }

    /// Answer a heard station: their call goes in Their call, or into Next
    /// if a contact is already in progress, and the transmit frequency moves
    /// onto them, since a JTTY contact is worked on one frequency.
    func adopt(callsign: String, frequency: Double? = nil) {
        if theirCall.isEmpty || theirCall == callsign {
            theirCall = callsign
            if let frequency {
                preferences.txFrequency = frequency
                if !preferences.rxFollowsTx { preferences.rxFrequency = frequency }
            }
        } else {
            queuedCall = callsign
        }
    }

    // MARK: - Errors

    func report(_ error: Error) {
        let localized = error as? LocalizedError
        var text = localized?.errorDescription ?? error.localizedDescription
        if let suggestion = localized?.recoverySuggestion { text += " " + suggestion }
        errorMessage = text
        log.error("\(text, privacy: .public)")
    }

    func dismissError() {
        errorMessage = nil
    }
}
