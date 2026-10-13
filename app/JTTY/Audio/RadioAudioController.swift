import Accelerate
import AVFoundation
import Foundation
import JTTYLib
import OSLog

private let log = Logger(subsystem: "com.w2asm.jtty", category: "audio")

/// Audio between the radio and the modem.
///
/// Receive: the hardware input is tapped at its native format, converted
/// to mono 12 kHz float and fed to the streaming receiver on a background
/// queue. JTTY has no time slots, so there is nothing to align to: the
/// receiver looks at every quarter frame as it arrives.
///
/// Transmit: a message is rendered in full and handed to the player node.
/// Buffers queue behind one another, so a second message sent while the
/// first is still going out follows it without a gap, which is how a
/// contest exchange is meant to chain.
///
/// The session runs in `.measurement` mode, which turns off the automatic
/// gain, noise suppression and echo cancellation iOS otherwise applies to
/// voice. All three act on exactly the quiet signals the decoder wants.
@Observable
final class RadioAudioController {

    enum AudioError: LocalizedError {
        case converterUnavailable
        case inputNotReady
        case session(Error)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable: "Cannot convert the audio input"
            case .inputNotReady: "Audio input not ready"
            case .session(let error): error.localizedDescription
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .inputNotReady: "Check that the audio interface is connected, then try again."
            case .converterUnavailable, .session: "Try disconnecting and reconnecting the interface."
            }
        }
    }

    /// A column of the spectrum, 200 to 2800 Hz, for the waterfall.
    struct SpectrumLine: Sendable {
        var magnitudes: [Float]
        static let minFrequency: Double = 200
        static let maxFrequency: Double = 2800
    }

    /// Called on the main actor with each receiver event.
    @ObservationIgnored var onEvents: (@MainActor ([JTTYReceiver.Event], Date) -> Void)?
    /// Called on the main actor as the receiver's running totals change.
    @ObservationIgnored var onStatistics: (@MainActor (JTTYReceiver.Statistics) -> Void)?
    /// Called on the main actor with a fresh spectrum line, about ten a second.
    @ObservationIgnored var onSpectrum: (@MainActor (SpectrumLine) -> Void)?
    /// Called on the main actor when the last queued transmission finishes.
    @ObservationIgnored var onTransmitFinished: (@MainActor () -> Void)?

    private(set) var isRunning = false
    private(set) var isTransmitting = false
    /// Whether the steady tune tone is going out.
    private(set) var isTuning = false
    /// What iOS is actually using, for the screen: "QMX Transceiver" or
    /// "iPhone Microphone", and the same for output. The difference between
    /// a radio that keys and one that does not is usually here.
    private(set) var inputRoute = "—"
    private(set) var outputRoute = "—"
    private(set) var isUSBRoute = false
    /// Messages queued on the player, including the one playing.
    private(set) var queuedTransmissions = 0
    /// Most recent input level, 0…1, for the meter.
    private(set) var inputLevel: Float = 0
    /// When the current session's sample clock started.
    private(set) var sessionStart = Date()

    var settings = ReceiverSettings() {
        didSet { dsp.async { [settings] in self.receiver?.settings = settings } }
    }

    private static let levelInterval: TimeInterval = 0.1
    @ObservationIgnored private var lastLevelPublished = Date.distantPast

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tunePlayer = AVAudioPlayerNode()
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    /// Set while an interruption (a call, Siri, another app's audio) has
    /// the session; cleared when the receiver is running again.
    private(set) var isInterrupted = false
    private var converter: AVAudioConverter?
    private var workFormat: AVAudioFormat?

    /// Everything touching the receiver happens here; it is not thread safe.
    private let dsp = DispatchQueue(label: "com.w2asm.jtty.dsp", qos: .userInitiated)
    private var receiver: JTTYReceiver?
    private var spectrum = SpectrumAnalyzer()
    private let recorder = AudioRecorder()
    /// Whether the receiver audio is being written to a file.
    private(set) var isRecording = false
    private(set) var recordingURL: URL?

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        try configureSession()

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.inputNotReady
        }
        guard let modemFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: JTTYProtocol.sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: modemFormat) else {
            throw AudioError.converterUnavailable
        }
        self.converter = converter
        self.workFormat = modemFormat

        sessionStart = Date()
        dsp.sync {
            let receiver = JTTYReceiver()
            receiver.settings = settings
            self.receiver = receiver
            spectrum.reset()
        }

        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: modemFormat)
        audioEngine.attach(tunePlayer)
        audioEngine.connect(tunePlayer, to: audioEngine.mainMixerNode, format: modemFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        readRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            self?.preferUSBInput()
            self?.readRoute()
        }
        // A call, Siri or another app taking the audio stops the engine, and
        // nothing restarts it unless we do. The same for a configuration
        // change, which is what plugging the radio in or out looks like to
        // the engine. Either one left unhandled is a receiver that went quiet
        // in the background without saying so.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                log.info("audio interrupted")
                isInterrupted = true
            case .ended:
                log.info("audio interruption ended")
                resume()
            @unknown default:
                break
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            log.info("audio engine configuration changed")
            self?.resume()
        }
        log.info("audio started, input \(inputFormat.sampleRate, privacy: .public) Hz, in \(self.inputRoute, privacy: .public), out \(self.outputRoute, privacy: .public)")
    }

    /// Bring the receiver back after an interruption or a configuration
    /// change. A full stop and start: the input format may have changed, and
    /// the converter and tap were built for the old one. Messages in
    /// progress are lost, which is the lesser evil.
    private func resume() {
        guard isRunning else { return }
        let wasRecording = isRecording
        stop()
        do {
            try start()
            if wasRecording { try? toggleRecording() }
            isInterrupted = false
            log.info("audio resumed, in \(self.inputRoute, privacy: .public), out \(self.outputRoute, privacy: .public)")
        } catch {
            // The hardware may not be ready the instant the interruption
            // ends; try once more shortly.
            log.error("audio resume failed: \(error.localizedDescription, privacy: .public)")
            isRunning = true
            isInterrupted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, isInterrupted else { return }
                isRunning = false
                if (try? start()) != nil { isInterrupted = false }
            }
        }
    }

    /// Where the audio is going. Shown on screen because it is the first
    /// thing to check when the radio does not key: a phone that has fallen
    /// back to its own microphone and earpiece decodes itself beautifully
    /// and never touches the radio.
    private func readRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputRoute = route.inputs.map(\.portName).joined(separator: ", ")
        outputRoute = route.outputs.map(\.portName).joined(separator: ", ")
        if inputRoute.isEmpty { inputRoute = "none" }
        if outputRoute.isEmpty { outputRoute = "none" }
        let external: Set<AVAudioSession.Port> = [.usbAudio, .headsetMic, .lineIn, .bluetoothHFP, .bluetoothA2DP, .headphones, .lineOut]
        isUSBRoute = route.inputs.contains { external.contains($0.portType) } ||
            route.outputs.contains { external.contains($0.portType) }
    }

    /// If a USB audio device is available, use it for input. iOS normally
    /// does this on its own, but not always when the device was plugged in
    /// before the session started.
    private func preferUSBInput() {
        let session = AVAudioSession.sharedInstance()
        guard let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) else { return }
        if session.currentRoute.inputs.first?.uid != usb.uid {
            try? session.setPreferredInput(usb)
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        player.stop()
        tunePlayer.stop()
        audioEngine.stop()
        audioEngine.detach(player)
        audioEngine.detach(tunePlayer)
        for observer in [routeObserver, interruptionObserver, configurationObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        routeObserver = nil
        interruptionObserver = nil
        configurationObserver = nil
        isTuning = false
        isInterrupted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        dsp.sync {
            receiver = nil
            recorder.stop()
        }
        isRecording = false
        isRunning = false
        isTransmitting = false
        queuedTransmissions = 0
        inputLevel = 0
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // Without `.defaultToSpeaker`, play-and-record sends output to
            // the earpiece, which is inaudible across a desk and misleading
            // when checking whether anything is being sent at all. A USB or
            // wired interface still takes precedence over the speaker.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.04)
            try session.setActive(true)
            preferUSBInput()
        } catch {
            throw AudioError.session(error)
        }
    }

    // MARK: - Receive

    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let workFormat else { return }
        let now = Date()
        if let channel = buffer.floatChannelData?[0], now.timeIntervalSince(lastLevelPublished) >= Self.levelInterval {
            lastLevelPublished = now
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
            Task { @MainActor [weak self] in self?.inputLevel = min(rms * 4, 1) }
        }

        let ratio = workFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else { return }
        let copy = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        let start = sessionStart
        dsp.async { [weak self] in
            guard let self, let receiver = self.receiver else { return }
            if let line = spectrum.append(copy) {
                Task { @MainActor [weak self] in self?.onSpectrum?(line) }
            }
            recorder.append(copy)
            let before = receiver.statistics
            let events = receiver.append(copy)
            if !events.isEmpty {
                Task { @MainActor [weak self] in self?.onEvents?(events, start) }
            }
            if receiver.statistics != before {
                let stats = receiver.statistics
                Task { @MainActor [weak self] in self?.onStatistics?(stats) }
            }
        }
    }

    // MARK: - Recording

    /// Start or stop writing the receiver audio to Documents as a WAV file.
    func toggleRecording() throws {
        if isRecording {
            dsp.sync { recorder.stop() }
            isRecording = false
        } else {
            guard isRunning else { return }
            var failure: Error?
            dsp.sync {
                do { try recorder.start() } catch { failure = error }
            }
            if let failure { throw failure }
            recordingURL = recorder.url
            isRecording = true
        }
    }

    // MARK: - Transmit

    /// Queue a transmission. It starts at once if nothing is playing, and
    /// otherwise follows whatever is.
    func transmit(_ transmission: JTTYTransmission) -> Bool {
        guard isRunning, let workFormat else { return false }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: workFormat, frameCapacity: AVAudioFrameCount(transmission.samples.count)
        ) else { return false }
        buffer.frameLength = AVAudioFrameCount(transmission.samples.count)
        transmission.samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }
        isTransmitting = true
        queuedTransmissions += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.queuedTransmissions = max(0, self.queuedTransmissions - 1)
                if self.queuedTransmissions == 0 {
                    self.isTransmitting = false
                    self.onTransmitFinished?()
                }
            }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// Stop transmitting now, dropping anything queued.
    func stopTransmitting() {
        player.stop()
        tunePlayer.stop()
        queuedTransmissions = 0
        isTransmitting = false
        isTuning = false
    }

    /// A steady tone at the transmit frequency, for setting the drive level
    /// and seeing the radio key. Stops after `duration` or on
    /// `stopTransmitting`.
    func tune(frequency: Double, gain: Float, duration: TimeInterval = 10) {
        guard isRunning, let workFormat, !isTuning else { return }
        let count = Int(duration * JTTYProtocol.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.floatChannelData![0]
        let ramp = Int(0.01 * JTTYProtocol.sampleRate)
        for i in 0..<count {
            var envelope = gain
            if i < ramp { envelope *= Float(i) / Float(ramp) }
            if i >= count - ramp { envelope *= Float(count - 1 - i) / Float(ramp) }
            samples[i] = envelope * Float(sin(2 * Double.pi * frequency * Double(i) / JTTYProtocol.sampleRate))
        }
        isTuning = true
        tunePlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.isTuning = false }
        }
        tunePlayer.play()
    }
}

/// A running spectrum of the 12 kHz input for the waterfall: a 4096-point
/// FFT every 1200 samples (a tenth of a second), 2.9 Hz per bin.
struct SpectrumAnalyzer {
    static let size = 4096
    static let hop = 1200
    private var pending: [Float] = []
    private let setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: size)
    private var smoothed: [Float] = []

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    mutating func reset() {
        pending.removeAll()
        smoothed.removeAll()
    }

    mutating func append(_ samples: [Float]) -> RadioAudioController.SpectrumLine? {
        pending.append(contentsOf: samples)
        guard pending.count >= Self.size else { return nil }
        let frame = Array(pending.suffix(Self.size))
        pending.removeFirst(min(Self.hop, pending.count))
        if pending.count > Self.size { pending.removeFirst(pending.count - Self.size) }

        var windowed = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))
        var real = [Float](repeating: 0, count: Self.size / 2)
        var imag = [Float](repeating: 0, count: Self.size / 2)
        var magnitudes = [Float](repeating: 0, count: Self.size / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.size / 2))
            }
        }
        let binHz = JTTYProtocol.sampleRate / Double(Self.size)
        let first = Int(RadioAudioController.SpectrumLine.minFrequency / binHz)
        let last = Int(RadioAudioController.SpectrumLine.maxFrequency / binHz)
        var line = (first..<last).map { 10 * log10f(magnitudes[$0] + 1e-12) }
        // A little temporal smoothing takes the sparkle out of noise without
        // smearing a 1.9-second frame.
        if smoothed.count == line.count {
            for i in line.indices { line[i] = 0.6 * line[i] + 0.4 * smoothed[i] }
        }
        smoothed = line
        return RadioAudioController.SpectrumLine(magnitudes: line)
    }
}
