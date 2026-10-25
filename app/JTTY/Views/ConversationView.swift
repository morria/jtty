import JTTYLib
import SwiftUI

/// One frequency: what has been heard and sent there, and the controls to
/// reply. A JTTY contact is worked on a single frequency, so this is the
/// natural unit, the way a thread is in a messaging app.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let frequency: Double
    var callsign: String?

    @State private var draft = ""
    @State private var contactToLog: LogEntry?
    @State private var showsStation = false
    @State private var sends = 0
    @State private var keyboard = KeyboardObserver()
    @FocusState private var composing: Bool

    private var lines: [TranscriptLine] { model.lines(near: frequency) }

    /// Who is here, most recent first, without us.
    private var stations: [String] {
        var seen: [String] = []
        for line in lines.reversed() where line.kind == .received {
            if let call = line.callsign, call != model.preferences.callsign, !seen.contains(call) { seen.append(call) }
        }
        return seen
    }

    /// The station, as a messaging app titles a thread by the person.
    private var title: String {
        if lines.isEmpty { return "New message" }
        return stations.isEmpty ? "\(Int(frequency)) Hz" : stations.prefix(2).joined(separator: " · ")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                transcript
                Divider()
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The keyboard's own frame, less the inset already there for the
            // tab bar, instead of SwiftUI's avoidance; see KeyboardObserver.
            .padding(.bottom, max(0, keyboard.overlap - geometry.safeAreaInsets.bottom))
        }
        .ignoresSafeArea(.keyboard)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            ToolbarItem(placement: .topBarTrailing) {
                ListenButton()
            }
        }
        .sheet(item: $contactToLog) { entry in
            LogEntryEditor(entry: entry, isNew: true) { model.record($0) }
        }
        .sheet(isPresented: $showsStation) {
            if let callsign = stations.first {
                StationCard(callsign: callsign, frequency: frequency)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .onAppear { model.enterConversation(at: frequency, callsign: callsign) }
        .onDisappear { if model.activeConversation == frequency { model.leaveConversation() } }
    }

    /// The station over the frequency; tap for the station card, as
    /// Messages opens a contact from its title.
    private var titleView: some View {
        Button {
            showsStation = true
        } label: {
            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(Int(frequency)) Hz")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(stations.isEmpty)
        .accessibilityLabel("\(title), \(Int(frequency)) hertz")
        .accessibilityHint(stations.isEmpty ? "" : "Shows the station")
    }

    /// "Today", "Yesterday", or the date, in UTC.
    private func dayLabel(for date: Date) -> String {
        if utcCalendar.isDateInToday(date) { return "Today" }
        if utcCalendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.timeZone = utcCalendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("Nothing here yet")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Call CQ, or wait for someone to.")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index == 0 || !utcCalendar.isDate(lines[index - 1].time, inSameDayAs: line.time) {
                            Text(dayLabel(for: line.time))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        TranscriptRow(line: line, showsFrequency: false, highlight: model.preferences.callsign)
                            .id(line.id)
                            .contextMenu {
                                ConversationContextMenu(line: line) { contactToLog = model.draftContact(from: line) }
                            }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // A tap on the transcript puts the keyboard away; a tap on the
            // controls below is part of writing the message and must not.
            .dismissesKeyboard()
            .onAppear {
                if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: lines.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: lines.last?.text) { _, _ in
                if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: keyboard.overlap) { _, _ in
                if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            TransmitBanner()
            RouteWarning()
            exchangeStrip
            if !recentCallsigns.isEmpty { callsignStrip }
            macroStrip
            composeBar
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// Stations heard lately, this conversation's first, then the rest of
    /// the band, newest first. Never us.
    private var recentCallsigns: [String] {
        var calls = stations
        for line in model.transcript.reversed() where line.kind == .received {
            if let call = line.callsign, call != model.preferences.callsign, !calls.contains(call) { calls.append(call) }
            if calls.count >= 8 { break }
        }
        return Array(calls.prefix(8))
    }

    /// Tap a station to address it, the way Messages suggests recent
    /// contacts under the To: line.
    private var callsignStrip: some View {
        @Bindable var model = model
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recentCallsigns, id: \.self) { call in
                    let selected = model.theirCall == call
                    Button {
                        model.theirCall = selected ? "" : call
                    } label: {
                        Text(call)
                            .font(.footnote.monospaced().weight(.medium))
                            .foregroundStyle(selected ? Color.white : Palette.teal)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Palette.teal : Palette.teal.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Addressed to \(call)" : "Address to \(call)")
                }
            }
            .padding(.horizontal)
        }
    }

    /// Who is being worked, who is next, and the serial number: the "To:"
    /// line of a new message, which is what it is.
    private var exchangeStrip: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            CallField(label: "To:", placeholder: "Callsign", text: $model.theirCall)
            if model.preferences.contestMode {
                CallField(label: "Next:", placeholder: "Callsign", text: $model.queuedCall)
            }
            if model.preferences.contestMode, model.preferences.exchangeProfile != .fieldDay {
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
        .overlay(alignment: .bottom) { Divider().padding(.horizontal) }
    }

    private var macroStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { index in
                    MacroButton(
                        label: model.preferences.macroLabels[index],
                        preview: model.preview(ofMacro: index),
                        insert: { append(model.preview(ofMacro: index)) },
                        send: { model.sendMacro(index) }
                    )
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

    /// Add a quick message to the draft, spaced as a word, and leave the
    /// cursor after it with the keyboard up, so a message can be built
    /// from quick messages and typing in any mix.
    private func append(_ text: String) {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        var base = draft
        if !base.isEmpty, !base.hasSuffix(" ") { base += " " }
        draft = base + word + " "
        composing = true
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
        sends += 1
    }
}

/// A callsign field with a label in front, like the To: line of a new
/// message: uppercase, monospaced, flexible width.
struct CallField: View {
    let label: String
    var placeholder = ""
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .onChange(of: text) { _, value in
                    let upper = value.uppercased()
                    if upper != value { text = upper }
                }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Listen / Stop, the same on every screen.
struct ListenButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isListening ? "Stop" : "Listen", systemImage: model.isListening ? "stop.fill" : "ear") {
            model.toggleListening()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(model.isListening ? Palette.salmon : Palette.teal)
    }
}

/// Shown while anything is going out, with the one control that matters.
struct TransmitBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isTransmitting || model.audio.isTuning {
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
    }
}

/// The phone talking to itself is the commonest reason nothing reaches the
/// radio, and it is invisible otherwise.
struct RouteWarning: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isListening, !model.audio.isUSBRoute {
            Label("Using \(model.audio.inputRoute) and \(model.audio.outputRoute), not a radio interface", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Palette.sand)
                .padding(.horizontal)
        }
    }
}

/// Actions on a message, inside a conversation.
struct ConversationContextMenu: View {
    @Environment(AppModel.self) private var model
    let line: TranscriptLine
    var logContact: () -> Void

    var body: some View {
        if let callsign = line.callsign, callsign != model.preferences.callsign {
            Button("Call \(callsign)", systemImage: "person.wave.2") {
                model.adopt(callsign: callsign, frequency: line.kind == .received ? line.frequency : nil)
            }
        }
        if line.kind == .received {
            Button("Log contact…", systemImage: "book.closed") { logContact() }
        }
        if line.kind == .sent {
            Button("Send again", systemImage: "arrow.counterclockwise") { model.send(text: line.text) }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
    }
}
