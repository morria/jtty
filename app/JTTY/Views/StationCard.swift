import SwiftUI

/// A station, the way Messages shows a contact from a thread's title:
/// who they are, what the transcript knows, and what to do about it.
struct StationCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let callsign: String
    let frequency: Double
    @State private var contactToLog: LogEntry?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var body: some View {
        let station = model.station(callsign, near: frequency)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        MonogramAvatar(text: callsign, size: 76)
                            .padding(.bottom, 4)
                        if let station, !station.grid.isEmpty {
                            Text("Grid \(station.grid)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let station {
                            Text("Heard \(messagingTimestamp(station.lastHeard.time)) · \(Int(station.lastHeard.frequency)) Hz")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") {
                        model.adopt(callsign: callsign, frequency: station?.lastHeard.frequency ?? frequency)
                        dismiss()
                    }
                    if let station {
                        Button("Log contact…", systemImage: "book.closed") {
                            contactToLog = model.draftContact(from: station.lastHeard)
                        }
                    }
                    if let url = URL(string: "https://www.qrz.com/db/\(callsign.split(separator: "/").max(by: { $0.count < $1.count }) ?? Substring(callsign))") {
                        Link(destination: url) {
                            Label("Look up on QRZ", systemImage: "safari")
                        }
                    }
                }
                if let station {
                    Section("Heard") {
                        LabeledContent("Last heard", value: Self.timeFormatter.string(from: station.lastHeard.time))
                        if let snr = station.lastHeard.snr {
                            LabeledContent("Signal") {
                                Text(String(format: "%+.0f dB", snr))
                                    .foregroundStyle(Palette.signalColor(for: snr))
                                    .monospacedDigit()
                            }
                        }
                        LabeledContent("Frequency", value: "\(Int(station.lastHeard.frequency)) Hz")
                        LabeledContent("Messages", value: "\(station.messageCount)")
                        if !station.grid.isEmpty {
                            LabeledContent("Grid", value: station.grid)
                        }
                    }
                }
            }
            .navigationTitle(callsign)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $contactToLog) { entry in
                LogEntryEditor(entry: entry, isNew: true) { model.record($0) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A face for a station: a circle in a colour that is always the same
/// for the same callsign, with the callsign on it.
struct MonogramAvatar: View {
    let text: String
    var size: CGFloat = 44

    private var hue: Double {
        // A stable hash: Swift's own is seeded per launch.
        let value = text.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return Double(abs(value) % 360) / 360
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.45, brightness: 0.85), Color(hue: hue, saturation: 0.55, brightness: 0.65)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(text)
                    .font(.system(size: size * (text.count > 5 ? 0.24 : 0.28), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
            }
            .accessibilityHidden(true)
    }
}
