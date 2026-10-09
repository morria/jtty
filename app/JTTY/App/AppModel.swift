import Foundation
import JTTYLib
import OSLog
import SwiftUI

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

    /// The first thing in the message that looks like a callsign.
    var callsign: String? {
        for word in text.split(separator: " ") where isStandardCallsign(String(word)) {
            return String(word)
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

    private(set) var transcript: [TranscriptLine] = []
    /// What the receiver has looked at this session.
    private(set) var statistics = JTTYReceiver.Statistics()
    private(set) var spectrumLines: [RadioAudioController.SpectrumLine] = []
    static let spectrumHistory = 90

    /// The station being worked and the one waiting.
    var theirCall = ""
    var queuedCall = ""

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
            ("RAN ALL NIGHT ON BAND NOISE - NO FALSE DECODES!", 1507, -9, 10, false, .received),
            ("CQ W1UE CQ", 1518, -11, 1, false, .received),
            ("CQ W2ASM CQ", 1500, 0, 1, false, .sent),
            ("W9XYZ", 1502, 4, 1, false, .received),
            ("W9XYZ 599 107", 1500, 0, 2, false, .sent),
            ("599 0", 1502, 5, 1, true, .received),
        ]
        for (index, line) in lines.enumerated() {
            transcript.append(TranscriptLine(
                id: Int64(1000 + index), kind: line.5, text: line.0, frequency: line.1,
                snr: line.5 == .sent ? nil : line.2, time: now.addingTimeInterval(Double(index - lines.count) * 7),
                isInProgress: line.4, frameCount: line.3, isOnFrequency: abs(line.1 - 1500) < 100
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
            spectrumLines.append(RadioAudioController.SpectrumLine(magnitudes: magnitudes))
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
            profile: preferences.exchangeProfile, configuredExchange: preferences.configuredExchange
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
        }
        if transcript.count > 500 { transcript.removeFirst(transcript.count - 500) }
    }

    private func handle(_ line: RadioAudioController.SpectrumLine) {
        spectrumLines.append(line)
        if spectrumLines.count > Self.spectrumHistory { spectrumLines.removeFirst() }
    }

    func clearTranscript() {
        transcript.removeAll()
    }

    func toggleRecording() {
        do { try audio.toggleRecording() } catch { report(error) }
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
    func chooseClearFrequency() {
        let recent = spectrumLines.suffix(30)
        guard recent.count >= 10, let width = recent.first?.magnitudes.count else { return }
        let binHz = JTTYProtocol.sampleRate / Double(SpectrumAnalyzer.size)
        let minHz = RadioAudioController.SpectrumLine.minFrequency
        var floor = [Float](repeating: 0, count: width)
        for line in recent where line.magnitudes.count == width {
            for i in 0..<width { floor[i] += line.magnitudes[i] }
        }
        let slot = Int(160 / binHz)
        let tx = preferences.txFrequency
        let low = max(300, tx - 300), high = min(2600, tx + 300)
        var best: (start: Int, energy: Float)?
        var start = Int((low - minHz) / binHz)
        let last = Int((high - minHz) / binHz) - slot
        while start <= last, start + slot <= width {
            var energy: Float = 0
            for i in start..<start + slot { energy += pow(10, floor[i] / 10) }
            if best == nil || energy < best!.energy { best = (start, energy) }
            start += 2
        }
        guard let best else { return }
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
        if preferences.choosesClearFrequency, theirCall.isEmpty, !audio.isTransmitting {
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
        if preferences.exchangeProfile != .fieldDay {
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

    // MARK: - Contacts

    /// What we sent as the exchange in this contact, if anything.
    private var lastExchangeSent: String {
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

    func logContact() {
        let call = theirCall.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else { return }
        let entry = LogEntry(
            callsign: call, time: Date(), band: preferences.band,
            frequency: preferences.dialFrequency + Int(preferences.txFrequency),
            exchangeSent: lastExchangeSent, exchangeReceived: lastExchangeReceived,
            myCallsign: preferences.callsign, myGrid: preferences.grid
        )
        logbook.add(entry)
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
