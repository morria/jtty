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
    /// The open conversation when the list and the conversation sit side by
    /// side (iPad); `path` carries it when they stack (iPhone).
    @State private var selected: Destination? = OperateView.initialPath.first
    @State private var contactToLog: LogEntry?
    @Environment(\.horizontalSizeClass) private var sizeClass

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

    /// Wide enough for two columns: the iPad, full screen or a big split.
    private var isSplit: Bool { sizeClass == .regular }

    var body: some View {
        if isSplit {
            NavigationSplitView {
                band
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 520)
            } detail: {
                if let selected {
                    ConversationView(frequency: selected.frequency, callsign: selected.callsign)
                        .id(selected.frequency)
                } else {
                    noConversation
                }
            }
        } else {
            NavigationStack(path: $path) {
                band
                    .navigationDestination(for: Destination.self) { destination in
                        ConversationView(frequency: destination.frequency, callsign: destination.callsign)
                    }
            }
        }
    }

    /// Open a conversation: beside the list or on top of it, as the width allows.
    private func open(_ destination: Destination) {
        if isSplit { selected = destination } else { path.append(destination) }
    }

    /// The detail column before anything is chosen.
    private var noConversation: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No conversation")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Choose one from the list, or New to call CQ.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            // Listen lives in the conversation's bar; keep it there before
            // one is open too.
            ToolbarItem(placement: .topBarTrailing) { ListenButton() }
        }
    }

    /// The band itself: waterfall, conversations or everything, and the
    /// transmit state. The same in both layouts.
    private var band: some View {
        VStack(spacing: 0) {
            if showsWaterfall {
                BandWaterfall { hz in open(Destination(frequency: hz)) }
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
        // No `dismissesKeyboard()` here: nothing on this screen takes
        // typing, and its tap gesture swallowed taps on the list rows.
        .navigationTitle(showsEverything ? "Band" : "Messages")
        .navigationBarTitleDisplayMode(.inline)
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
                    open(Destination(frequency: model.newConversationFrequency()))
                }
            }
            if !isSplit {
                // Beside a conversation the button in its own bar is enough.
                ToolbarItem(placement: .topBarTrailing) {
                    ListenButton()
                }
            }
        }
    }

    // MARK: - Conversations

    /// Which row is highlighted in the split layout: the open conversation's
    /// frequency. Selecting a row opens it with whoever is there.
    private var selectedFrequency: Binding<Double?> {
        Binding(
            get: { selected?.frequency },
            set: { hz in
                guard let hz else { return }
                let band = model.bands.first { $0.frequency == hz }
                open(Destination(frequency: hz, callsign: band?.callsigns(excluding: model.preferences.callsign).first))
            }
        )
    }

    private var conversations: some View {
        let bands = model.bands
        return List(selection: selectedFrequency) {
            if bands.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(bands) { band in
                let row = BandRow(
                    band: band, myCallsign: model.preferences.callsign,
                    isTransmitFrequency: abs(band.frequency - model.preferences.txFrequency) <= AppModel.conversationHalfWidth,
                    unread: model.unreadCount(in: band)
                )
                Group {
                    if isSplit {
                        row.tag(band.frequency)
                    } else {
                        NavigationLink(value: Destination(frequency: band.frequency, callsign: band.callsigns(excluding: model.preferences.callsign).first)) { row }
                    }
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
                            open(Destination(frequency: line.frequency, callsign: line.kind == .received ? line.callsign : nil))
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
                    ? "Everything heard on the band appears here. Tap a message to open its frequency."
                    : "Each station heard becomes a conversation here. Tap one to join it.")
                 : "Connect the radio's audio and tap Listen.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Group {
                if model.isListening {
                    Button {
                        open(Destination(frequency: model.newConversationFrequency()))
                    } label: {
                        Label("Call CQ", systemImage: "square.and.pencil").foregroundStyle(.white)
                    }
                } else {
                    Button {
                        model.toggleListening()
                    } label: {
                        // Explicitly white: on the teal pill the icon
                        // otherwise takes the tint and disappears.
                        Label("Listen", systemImage: "ear").foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.teal)
            .padding(.top, 10)
            // What a messaging app cannot promise here, said up front.
            Text("Messages are a few words at a time, a couple of seconds each, and anyone on the band can read them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func contextMenu(for line: TranscriptLine) -> some View {
        if let callsign = line.callsign, callsign != model.preferences.callsign, line.kind == .received {
            Button("Call \(callsign)", systemImage: "person.wave.2") {
                model.adopt(callsign: callsign, frequency: line.frequency)
                open(Destination(frequency: line.frequency, callsign: callsign))
            }
        }
        Button("Open \(Int(line.frequency)) Hz", systemImage: "bubble.left.and.bubble.right") {
            open(Destination(frequency: line.frequency))
        }
        if line.kind == .received {
            Button("Log contact…", systemImage: "book.closed") { contactToLog = model.draftContact(from: line) }
        }
        if line.kind == .sent {
            Button("Send again", systemImage: "arrow.counterclockwise") { model.send(text: line.text) }
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
    var unread = 0

    private var title: String {
        let calls = band.callsigns(excluding: myCallsign)
        return calls.isEmpty ? "\(Int(band.frequency)) Hz" : calls.prefix(3).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread, where Messages puts its dot.
            Circle()
                .fill(unread > 0 ? Palette.teal : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 20)
                .padding(.leading, -4)
                .accessibilityHidden(true)
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
                        .fontWeight(unread > 0 ? .bold : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let latest = band.latest {
                        Text(messagingTimestamp(latest.time))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(unread > 0 ? Palette.teal : .secondary)
                    }
                }
                if let latest = band.latest {
                    HStack(spacing: 4) {
                        if latest.kind == .sent {
                            Image(systemName: latest.heardBack ? "checkmark.circle.fill" : latest.isInProgress ? "arrow.up.circle" : "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(latest.heardBack ? Palette.teal : .secondary)
                                .accessibilityLabel(latest.heardBack ? "Heard" : latest.isInProgress ? "Sending" : "Sent")
                        }
                        Text((latest.kind == .sent ? "You: " : "") + latest.text)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(unread > 0 ? .primary : .secondary)
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
        .accessibilityLabel("\(title), \(Int(band.frequency)) hertz, \(unread > 0 ? "\(unread) unread, " : "")\(band.latest?.text ?? "nothing heard yet")")
    }
}

/// A time the way a messaging app writes one, in UTC like everything
/// else here: the time today, "Yesterday", otherwise the date.
func messagingTimestamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let formatter = DateFormatter()
    formatter.timeZone = calendar.timeZone
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else if calendar.isDateInYesterday(date) {
        return "Yesterday"
    } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
        formatter.dateFormat = "d MMM"
    } else {
        formatter.dateFormat = "d MMM yyyy"
    }
    return formatter.string(from: date)
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

/// One quick message: what it is for, and exactly what it would send. A tap
/// puts it in the message box to look over or edit; a long press sends it
/// straight away.
struct MacroButton: View {
    let label: String
    let preview: String
    let insert: () -> Void
    let send: () -> Void

    @State private var isPressed = false
    @State private var sendCount = 0

    var body: some View {
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
        .opacity(isPressed ? 0.5 : 1)
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: insert)
        .onLongPressGesture(minimumDuration: 0.45, pressing: { isPressed = $0 }) {
            sendCount += 1
            send()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(preview)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Puts the message in the message box. Long press to send it now.")
        .accessibilityAction(named: "Send now", send)
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
    /// Our callsign, picked out in received text so "is this for me?" is
    /// answered at a glance.
    var highlight: String?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private var isSent: Bool { line.kind == .sent }

    private var text: AttributedString {
        var attributed = AttributedString(line.text.isEmpty ? " " : line.text)
        guard !isSent, let highlight, !highlight.isEmpty else { return attributed }
        var search = attributed.startIndex
        while let range = attributed[search...].range(of: highlight) {
            let before = range.lowerBound == attributed.startIndex || attributed.characters[attributed.index(beforeCharacter: range.lowerBound)] == " "
            let after = range.upperBound == attributed.endIndex || attributed.characters[range.upperBound] == " "
            if before, after {
                attributed[range].font = .body.monospaced().weight(.bold)
                attributed[range].foregroundColor = Palette.teal
            }
            search = range.upperBound
        }
        return attributed
    }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 40) }
            VStack(alignment: isSent ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(text)
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
                        Label(line.snr.map { String(format: "Heard %+.0f dB", $0) } ?? "Heard", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.white.opacity(0.9))
                    } else if isSent {
                        // Honest words: the audio went out, or is going.
                        Text(line.isInProgress ? "Sending…" : "Sent")
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
