import JTTYLib
import SwiftUI

/// The operating screen: the band as a transcript, with the exchange
/// controls underneath. Messages heard come in on the left as they build;
/// messages sent go out on the right.
struct OperateView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var showsWaterfall = true
    @FocusState private var composing: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                if showsWaterfall {
                    WaterfallView(
                        lines: model.spectrumLines,
                        rxFrequency: model.receiveFrequency,
                        txFrequency: model.preferences.txFrequency
                    ) { hz in
                        model.preferences.txFrequency = hz
                        if !model.preferences.rxFollowsTx { model.preferences.rxFrequency = hz }
                    }
                    .frame(height: 96)
                    .overlay(alignment: .topTrailing) {
                        // Input level, so the interface gain can be set
                        // without guessing. Only meaningful while listening.
                        if model.isListening {
                            HStack(spacing: 8) {
                                if model.audio.isRecording {
                                    Label("REC", systemImage: "record.circle.fill")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(Palette.salmon)
                                        .symbolEffect(.pulse)
                                }
                                InputLevelMeter(level: model.audio.inputLevel)
                            }
                            .padding(6)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                            .padding(6)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
                transcript
                Divider()
                controls
            }
            .background(Color(.systemGroupedBackground))
            .dismissesKeyboard()
            .navigationTitle("JTTY")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $model.isConfirmingBand) {
                BandSheet()
                    .presentationDetents([.medium])
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Waterfall", isOn: $showsWaterfall)
                        Button("Clear", systemImage: "trash") { model.clearTranscript() }
                            .disabled(model.transcript.isEmpty)
                        Button(model.audio.isTuning ? "Stop tuning" : "Tune (10 s tone)", systemImage: "tuningfork") { model.tune() }
                        Toggle(isOn: Binding(get: { model.audio.isRecording }, set: { _ in model.toggleRecording() })) {
                            Label("Record audio", systemImage: "record.circle")
                        }
                        .disabled(!model.isListening)
                        Section("Audio route") {
                            Text("In: \(model.audio.inputRoute)")
                            Text("Out: \(model.audio.outputRoute)")
                        }
                        Section("Receiver this session") {
                            // Sync hits without decodes are JTTY frames the
                            // decoder could not read; none at all means what
                            // is on the waterfall is not JTTY.
                            Text("\(model.statistics.syncHits) sync hits · \(model.statistics.decodes) frames decoded")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isListening ? "Stop" : "Listen", systemImage: model.isListening ? "stop.fill" : "ear") {
                        model.toggleListening()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(model.isListening ? Palette.salmon : Palette.teal)
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.transcript.isEmpty {
                        emptyState
                    }
                    ForEach(model.transcript) { line in
                        TranscriptRow(line: line)
                            .id(line.id)
                            .contextMenu { contextMenu(for: line) }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.transcript.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: model.transcript.last?.text) { _, _ in
                if let id = model.transcript.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.isListening ? "waveform" : "ear")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative, isActive: model.isListening)
            Text(model.isListening ? "Listening" : "Not listening")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(model.isListening
                 ? "Messages appear here as their frames arrive. Tap one to call that station."
                 : "Connect the radio's audio and tap Listen.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func contextMenu(for line: TranscriptLine) -> some View {
        if let callsign = line.callsign, callsign != model.preferences.callsign {
            Button("Call \(callsign)", systemImage: "person.wave.2") {
                model.adopt(callsign: callsign, frequency: line.kind == .received ? line.frequency : nil)
            }
        }
        Button("Set frequency to \(Int(line.frequency)) Hz", systemImage: "dial.medium") {
            model.preferences.txFrequency = line.frequency
            if !model.preferences.rxFollowsTx { model.preferences.rxFrequency = line.frequency }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
    }

    // MARK: - Controls

    private var controls: some View {
        @Bindable var model = model
        return VStack(spacing: 8) {
            if model.isTransmitting || model.audio.isTuning {
                transmitBanner
            }
            if model.isListening, !model.audio.isUSBRoute {
                // The phone talking to itself is the commonest reason nothing
                // reaches the radio, and it is invisible otherwise.
                Label("Using \(model.audio.inputRoute) and \(model.audio.outputRoute), not a radio interface", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.sand)
                    .padding(.horizontal)
            }
            exchangeStrip
            macroStrip
            composeBar
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var transmitBanner: some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative)
            Text(model.audio.isTuning ? "Tuning" : "Transmitting")
                .font(.subheadline.weight(.semibold))
            if model.audio.queuedTransmissions > 1 {
                Text("· \(model.audio.queuedTransmissions) queued")
                    .font(.subheadline)
            }
            Spacer()
            Button("Stop", role: .destructive) { model.stopTransmitting() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Palette.salmon)
        }
        .foregroundStyle(Palette.salmon)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Palette.salmon.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    /// Who is being worked, who is next, and the serial number.
    private var exchangeStrip: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            callField("Their call", text: $model.theirCall)
            callField("Next", text: $model.queuedCall)
            if model.preferences.exchangeProfile != .fieldDay {
                // The readout and the stepper are one control that must not
                // wrap, however narrow the row gets with the keyboard up.
                HStack(spacing: 6) {
                    Text(String(format: "%03d", model.preferences.serialNumber))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText())
                    Stepper("Serial number", value: $model.preferences.serialNumber, in: 0...131071)
                        .labelsHidden()
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Serial number")
                .accessibilityValue(String(format: "%03d", model.preferences.serialNumber))
            }
        }
        .padding(.horizontal)
    }

    private func callField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .onChange(of: text.wrappedValue) { _, value in
                let upper = value.uppercased()
                if upper != value { text.wrappedValue = upper }
            }
    }

    /// The eight quick messages, each showing what it would send.
    private var macroStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { index in
                    MacroButton(
                        label: NativeMacro.defaultLabels[index],
                        preview: model.preview(ofMacro: index)
                    ) {
                        model.sendMacro(index)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var composeBar: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .focused($composing)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .overlay(alignment: .topTrailing) {
            if let frames = frameCount(for: draft), frames > 0 {
                Text("\(frames) frame\(frames == 1 ? "" : "s") · \(String(format: "%.1f", Double(frames) * JTTYProtocol.frameDuration)) s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 58)
                    .offset(y: -14)
            }
        }
    }

    private func frameCount(for text: String) -> Int? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? JTTYEncoder.pack(text: text, profile: model.preferences.exchangeProfile).frameCount
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.send(text: text)
        draft = ""
        composing = false
    }
}

/// One quick message: what it is for, and exactly what it would send.
struct MacroButton: View {
    let label: String
    let preview: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.teal)
                Text(preview.isEmpty ? "—" : preview)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(preview)
    }
}

/// Asked before the first transmission in a while: nothing ties the band
/// setting to the radio, and a wrong band is the commonest logging error.
struct BandSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var editingNumber: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Band", selection: $model.preferences.band) {
                        ForEach(Band.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.preferences.band) { _, band in
                        model.preferences.dialFrequency = band.suggestedDialFrequency
                    }
                    LabeledContent("Dial frequency") {
                        HStack(spacing: 4) {
                            TextField("14080.0", value: $model.preferences.dialKilohertz, format: .number.grouping(.never).precision(.fractionLength(0...3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($editingNumber)
                                .frame(maxWidth: 120)
                            Text("kHz").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("It has been a while since the last transmission. Check the radio is still where the log thinks it is.")
                }
            }
            .navigationTitle("Which band?")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .dismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelBandConfirmation() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transmit") { model.confirmBand() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// One line of the transcript.
struct TranscriptRow: View {
    let line: TranscriptLine

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private var isSent: Bool { line.kind == .sent }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 40) }
            VStack(alignment: isSent ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.body.monospaced())
                        .foregroundStyle(isSent ? Color.white : .primary)
                        .textSelection(.enabled)
                    if line.isInProgress {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .symbolEffect(.variableColor.iterative.reversing)
                            .foregroundStyle(isSent ? Color.white.opacity(0.8) : Color.secondary)
                            .accessibilityLabel(isSent ? "Sending" : "Still arriving")
                    }
                }
                HStack(spacing: 6) {
                    Text(Self.timeFormatter.string(from: line.time))
                    Text("\(Int(line.frequency)) Hz")
                    if let snr = line.snr {
                        Text(String(format: "%+.0f dB", snr))
                            .foregroundStyle(isSent ? Color.white.opacity(0.8) : Palette.signalColor(for: snr))
                    }
                    if line.frameCount > 1 {
                        Text("\(line.frameCount) frames")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSent ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSent ? AnyShapeStyle(Palette.teal) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if !isSent, line.isOnFrequency {
                    // On the receive frequency: the one worth reading first.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.teal)
                        .frame(width: 3)
                        .padding(.vertical, 6)
                        .offset(x: -8)
                }
            }
            if !isSent { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isSent ? "Sent" : "Heard") \(line.text)")
    }
}
