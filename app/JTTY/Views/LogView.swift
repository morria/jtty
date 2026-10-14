import SwiftUI

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: LogEntry?

    /// Days are UTC days, like the times.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy 'UTC'"
        return formatter
    }()

    private var days: [(Date, [LogEntry])] {
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let grouped = Dictionary(grouping: model.logbook.entries) { utc.startOfDay(for: $0.time) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.logbook.entries.isEmpty {
                    ContentUnavailableView(
                        "No contacts yet",
                        systemImage: "book.closed",
                        description: Text("A contact is logged when you send TU to the station in Their call, or with the button above.")
                    )
                } else {
                    List {
                        ForEach(days, id: \.0) { day, entries in
                            Section(Self.dayFormatter.string(from: day)) {
                                ForEach(entries) { entry in
                                    Button { editing = entry } label: { LogRow(entry: entry) }
                                        .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    for index in offsets { model.logbook.remove(entries[index]) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .dismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: ADIFDocument(text: model.logbook.adif), preview: SharePreview("JTTY log")) {
                        Label("Export ADIF", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.logbook.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Log contact", systemImage: "plus") { model.logContact() }
                        .disabled(model.theirCall.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(item: $editing) { entry in
                LogEntryEditor(entry: entry) { model.logbook.update($0) }
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.time))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.callsign).font(.body.monospaced().weight(.semibold))
                Text("Sent \(entry.exchangeSent.isEmpty ? "—" : entry.exchangeSent) · Rcvd \(entry.exchangeReceived.isEmpty ? "—" : entry.exchangeReceived)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.band.rawValue).font(.caption).foregroundStyle(.secondary)
                if !entry.theirGrid.isEmpty || !entry.state.isEmpty {
                    Text([entry.theirGrid, entry.state].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if entry.uploadedToQRZ {
                Image(systemName: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(Palette.teal)
                    .accessibilityLabel("Uploaded to QRZ")
            }
        }
        .contentShape(Rectangle())
    }
}

struct LogEntryEditor: View {
    @State var entry: LogEntry
    var isNew = false
    let onSave: (LogEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    LabeledContent("Callsign") {
                        TextField("", text: $entry.callsign).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    DatePicker("Time (UTC)", selection: $entry.time)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    Picker("Band", selection: $entry.band) {
                        ForEach(Band.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Location") {
                    LabeledContent("Name") {
                        TextField("", text: $entry.name).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    LabeledContent("Grid") {
                        TextField("FN42", text: $entry.theirGrid).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    LabeledContent("QTH") {
                        TextField("Town", text: $entry.qth).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    LabeledContent("State") {
                        TextField("", text: $entry.state).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    LabeledContent("Country") {
                        TextField("", text: $entry.country).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                }
                Section("Exchange") {
                    LabeledContent("Sent") {
                        TextField("599 001", text: $entry.exchangeSent).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    LabeledContent("Received") {
                        TextField("599 001", text: $entry.exchangeReceived).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    TextField("Notes", text: $entry.notes)
                }
            }
            .navigationTitle(isNew ? "Log contact" : "Contact")
            .navigationBarTitleDisplayMode(.inline)
            .dismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Log" : "Save") {
                        entry.callsign = entry.callsign.trimmingCharacters(in: .whitespaces).uppercased()
                        entry.theirGrid = entry.theirGrid.trimmingCharacters(in: .whitespaces).uppercased()
                        onSave(entry)
                        dismiss()
                    }
                    .disabled(entry.callsign.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
