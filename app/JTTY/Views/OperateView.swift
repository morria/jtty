import JTTYLib
import SwiftUI

/// The band: everything heard on every frequency, as one wall of text, and
/// the way into any one conversation.
struct OperateView: View {
    @Environment(AppModel.self) private var model
    @State private var showsWaterfall = true
    /// Conversations by frequency, or everything in one stream.
    @AppStorage("showsEverything") private var showsEverything = false
    @State private var path: [Destination] = OperateView.initialPath
    @State private var contactToLog: LogEntry?

    /// `-conversation 1507` on a debug launch opens that frequency.
    private static var initialPath: [Destination] {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-conversation"), index + 1 < CommandLine.arguments.count,
           let hz = Double(CommandLine.arguments[index + 1]) {
            return [Destination(frequency: hz)]
        }
        #endif
        return []
    }

    /// A conversation to open: a frequency, and the callsign that led there.
    struct Destination: Hashable {
        var frequency: Double
        var callsign: String?
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if showsWaterfall {
                    BandWaterfall { hz in path.append(Destination(frequency: hz)) }
                }
                if showsEverything {
                    transcript
                } else {
                    conversations
                }
                VStack(spacing: 8) {
                    TransmitBanner()
                    RouteWarning()
                }
            }
            .background(Color(.systemGroupedBackground))
            .dismissesKeyboard()
            .navigationTitle("Band")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                ConversationView(frequency: destination.frequency, callsign: destination.callsign)
            }
            .sheet(item: $contactToLog) { entry in
                LogEntryEditor(entry: entry, isNew: true) { model.record($0) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Show", selection: $showsEverything) {
                            Label("Conversations", systemImage: "bubble.left.and.bubble.right").tag(false)
                            Label("Everything", systemImage: "text.alignleft").tag(true)
                        }
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
                            Text("\(model.statistics.syncHits) sync hits · \(model.statistics.decodes) frames decoded")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New conversation", systemImage: "square.and.pencil") {
                        path.append(Destination(frequency: model.newConversationFrequency()))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ListenButton()
                }
            }
        }
    }

    // MARK: - Conversations

    private var conversations: some View {
        let bands = model.bands
        return List {
            if bands.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(bands) { band in
                Button {
                    path.append(Destination(frequency: band.frequency, callsign: band.callsigns(excluding: model.preferences.callsign).first))
                } label: {
                    BandRow(band: band, myCallsign: model.preferences.callsign, isTransmitFrequency: abs(band.frequency - model.preferences.txFrequency) <= AppModel.conversationHalfWidth)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .contextMenu {
                    if let line = band.latest { contextMenu(for: line) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                        Button {
                            path.append(Destination(frequency: line.frequency, callsign: line.kind == .received ? line.callsign : nil))
                        } label: {
                            TranscriptRow(line: line, showsFrequency: true)
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .contextMenu { contextMenu(for: line) }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
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
                 ? (showsEverything
                    ? "Everything heard on the band appears here. Tap a message to open its frequency, or New to call CQ."
                    : "Each frequency with traffic becomes a conversation here. Tap one to join it, or New to call CQ.")
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
        if let callsign = line.callsign, callsign != model.preferences.callsign, line.kind == .received {
            Button("Call \(callsign)", systemImage: "person.wave.2") {
                model.adopt(callsign: callsign, frequency: line.frequency)
                path.append(Destination(frequency: line.frequency, callsign: callsign))
            }
        }
        Button("Open \(Int(line.frequency)) Hz", systemImage: "bubble.left.and.bubble.right") {
            path.append(Destination(frequency: line.frequency))
        }
        if line.kind == .received {
            Button("Log contact…", systemImage: "book.closed") { contactToLog = model.draftContact(from: line) }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
    }
}

/// One conversation in the list: the frequency, who is there, and the
/// latest thing said.
struct BandRow: View {
    let band: FrequencyBand
    let myCallsign: String
    let isTransmitFrequency: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private var title: String {
        let calls = band.callsigns(excluding: myCallsign)
        return calls.isEmpty ? "\(Int(band.frequency)) Hz" : calls.prefix(3).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The frequency, where a messaging app would put a face.
            VStack(spacing: 2) {
                Text("\(Int(band.frequency))")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text("Hz")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 48)
            .background(
                (isTransmitFrequency ? Palette.teal.opacity(0.18) : Color(.tertiarySystemFill)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isTransmitFrequency ? Palette.teal : .clear, lineWidth: 1.5)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let latest = band.latest {
                        Text(Self.timeFormatter.string(from: latest.time))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let latest = band.latest {
                    HStack(spacing: 4) {
                        Text((latest.kind == .sent ? "You: " : "") + latest.text)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if latest.isInProgress {
                            Image(systemName: "ellipsis")
                                .font(.caption)
                                .symbolEffect(.variableColor.iterative.reversing)
                                .foregroundStyle(Palette.teal)
                                .accessibilityLabel("Still arriving")
                        }
                    }
                    HStack(spacing: 8) {
                        if let snr = latest.snr {
                            Text(String(format: "%+.0f dB", snr))
                                .foregroundStyle(Palette.signalColor(for: snr))
                        }
                        Text("\(band.lines.count) message\(band.lines.count == 1 ? "" : "s")")
                        if isTransmitFrequency {
                            Text("TX").foregroundStyle(Palette.teal).fontWeight(.semibold)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                } else {
                    Text("Nothing heard yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(Int(band.frequency)) hertz, \(band.latest?.text ?? "nothing heard yet")")
    }
}

/// The waterfall and the level meter, in a view of their own so their ten
/// updates a second never touch the transcript above them.
struct BandWaterfall: View {
    @Environment(AppModel.self) private var model
    let onTap: (Double) -> Void

    var body: some View {
        WaterfallView(
            image: model.waterfall.image,
            rxFrequency: model.receiveFrequency,
            txFrequency: model.preferences.txFrequency,
            onTap: onTap
        )
        .frame(height: 96)
        .overlay(alignment: .topTrailing) {
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
    var showsFrequency = true

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
                        .multilineTextAlignment(isSent ? .trailing : .leading)
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
                    if showsFrequency {
                        Text("\(Int(line.frequency)) Hz")
                            .foregroundStyle(isSent ? Color.white.opacity(0.9) : Palette.teal)
                    }
                    if isSent, line.heardBack {
                        // The radio's monitor heard it: it went out.
                        Label(line.snr.map { String(format: "heard %+.0f dB", $0) } ?? "heard", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.white.opacity(0.9))
                    } else if let snr = line.snr {
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
                if !isSent, line.isOnFrequency, showsFrequency {
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isSent ? "Sent" : "Heard") \(line.text), \(Int(line.frequency)) hertz")
    }
}
