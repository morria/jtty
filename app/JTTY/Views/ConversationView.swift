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
    @FocusState private var composing: Bool

    private var lines: [TranscriptLine] { model.lines(near: frequency) }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            controls
        }
        .background(Color(.systemGroupedBackground))
        .dismissesKeyboard()
        .navigationTitle("\(Int(frequency)) Hz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ListenButton()
            }
        }
        .onAppear { model.enterConversation(at: frequency, callsign: callsign) }
        .onDisappear { if model.activeConversation == frequency { model.leaveConversation() } }
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
                    ForEach(lines) { line in
                        TranscriptRow(line: line, showsFrequency: false)
                            .id(line.id)
                            .contextMenu { ConversationContextMenu(line: line) }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: lines.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: lines.last?.text) { _, _ in
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
            macroStrip
            composeBar
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// Who is being worked, who is next, and the serial number.
    private var exchangeStrip: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            CallField(label: "Their call", text: $model.theirCall)
            if model.preferences.contestMode {
                CallField(label: "Next", text: $model.queuedCall)
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
    }

    private var macroStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { index in
                    MacroButton(label: model.preferences.macroLabels[index], preview: model.preview(ofMacro: index)) {
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

/// A callsign field: uppercase, monospaced, flexible width.
struct CallField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        TextField(label, text: $text)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .onChange(of: text) { _, value in
                let upper = value.uppercased()
                if upper != value { text = upper }
            }
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

    var body: some View {
        if let callsign = line.callsign, callsign != model.preferences.callsign {
            Button("Call \(callsign)", systemImage: "person.wave.2") {
                model.adopt(callsign: callsign, frequency: line.kind == .received ? line.frequency : nil)
            }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
    }
}
