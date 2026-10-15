import JTTYLib
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var locator = GridLocator()
    @FocusState private var editingNumber: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                station($model)
                frequencies($model)
                operating($model)
                if model.preferences.contestMode { exchange($model) }
                macros($model)
                logging($model)
                about
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .dismissesKeyboard()
        }
    }

    private func station(_ model: Bindable<AppModel>) -> some View {
        Section {
            LabeledContent("Callsign") {
                TextField("W2ASM", text: model.preferences.callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Grid square")
                TextField("FN20", text: model.preferences.grid)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                Button {
                    locator.locate { model.wrappedValue.preferences.grid = $0 }
                } label: {
                    if locator.isLocating { ProgressView() } else { Image(systemName: "location") }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Find my grid square")
            }
            Picker("Band", selection: model.preferences.band) {
                ForEach(Band.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: model.wrappedValue.preferences.band) { _, band in
                model.wrappedValue.preferences.dialFrequency = band.suggestedDialFrequency
            }
            LabeledContent("Dial frequency") {
                HStack(spacing: 4) {
                    TextField("14080.0", value: model.preferences.dialKilohertz, format: .number.grouping(.never).precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($editingNumber)
                        .frame(maxWidth: 120)
                    Text("kHz").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Station")
        } footer: {
            if let error = locator.errorMessage {
                Text(error).foregroundStyle(Palette.salmon)
            } else {
                Text("The band and dial frequency are for the log. JTTY has no fixed watering holes yet; set the dial to where the radio actually is.")
            }
        }
    }

    private func frequencies(_ model: Bindable<AppModel>) -> some View {
        Section {
            VStack(alignment: .leading) {
                LabeledContent("Transmit at") {
                    Text("\(Int(model.wrappedValue.preferences.txFrequency)) Hz").monospacedDigit()
                }
                Slider(value: model.preferences.txFrequency, in: 300...2600, step: 10)
            }
            Toggle("Choose a clear frequency", isOn: model.preferences.choosesClearFrequency)
            Toggle("Receive on the transmit frequency", isOn: model.preferences.rxFollowsTx)
            if !model.wrappedValue.preferences.rxFollowsTx {
                VStack(alignment: .leading) {
                    LabeledContent("Receive at") {
                        Text("\(Int(model.wrappedValue.preferences.rxFrequency)) Hz").monospacedDigit()
                    }
                    Slider(value: model.preferences.rxFrequency, in: 300...2600, step: 10)
                }
            }
            VStack(alignment: .leading) {
                LabeledContent("Receive tolerance") {
                    Text("±\(Int(model.wrappedValue.preferences.rxTolerance)) Hz").monospacedDigit()
                }
                Slider(value: model.preferences.rxTolerance, in: 20...500, step: 10)
            }
            Toggle("Decode the whole passband", isOn: model.preferences.searchesWholePassband)
            VStack(alignment: .leading) {
                LabeledContent("Transmit level") {
                    Text("\(Int(model.wrappedValue.preferences.txGain * 100))%").monospacedDigit()
                }
                Slider(value: model.preferences.txGain, in: 0.05...1, step: 0.05)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("""
                Now using \(model.wrappedValue.audio.inputRoute) for input and \(model.wrappedValue.audio.outputRoute) for output. \
                A radio connected over USB should appear by name in both; the phone's own microphone \
                and speaker mean nothing is reaching the radio.

                With a clear frequency chosen, calling CQ first moves the transmit frequency to the \
                quietest spot within 300 Hz, judged from the last few seconds of the waterfall. \
                Answering a station always moves onto their frequency. Turn it off to stay exactly \
                where the slider is.

                Signals within the tolerance of the receive frequency are searched hardest and marked \
                in the transcript. With the whole passband on, everything from 200 to 2800 Hz is \
                decoded as well, which costs some battery.

                Set the transmit level so the radio shows little or no ALC movement. A signal driven \
                into compression is a wide one, and you will not hear it happening.
                """)
        }
    }

    private func operating(_ model: Bindable<AppModel>) -> some View {
        Section {
            Toggle("Contest mode", isOn: model.preferences.contestMode)
        } header: {
            Text("Operating")
        } footer: {
            Text("Contest mode adds the serial number, a queued next station, the contest exchange profiles and WSJT-X's contest quick messages. Off, a contact is a conversation: your call, theirs, and whatever you type.")
        }
    }

    private func exchange(_ model: Bindable<AppModel>) -> some View {
        Section {
            Picker("Exchange", selection: model.preferences.exchangeProfile) {
                ForEach(ExchangeProfile.allCases) { Text($0.displayName).tag($0) }
            }
            switch model.wrappedValue.preferences.exchangeProfile {
            case .none:
                Stepper(value: model.preferences.serialNumber, in: 0...131071) {
                    LabeledContent("Next serial", value: String(format: "%03d", model.wrappedValue.preferences.serialNumber))
                }
            case .fieldDay:
                LabeledContent("Class and section") {
                    TextField("1D EMA", text: model.preferences.configuredExchange)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing).monospaced()
                }
            case .rttyRoundup:
                LabeledContent("State or province") {
                    TextField("Serial if blank", text: model.preferences.configuredExchange)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing).monospaced()
                }
                Stepper(value: model.preferences.serialNumber, in: 0...131071) {
                    LabeledContent("Next serial", value: String(format: "%03d", model.wrappedValue.preferences.serialNumber))
                }
            }
        } header: {
            Text("Contest exchange")
        } footer: {
            Text(exchangeFooter(model.wrappedValue.preferences.exchangeProfile))
        }
    }

    private func exchangeFooter(_ profile: ExchangeProfile) -> String {
        switch profile {
        case .none:
            "%E sends 599 and the serial number, which moves on each time you send TU. Numbers typed by hand are sent exactly as written."
        case .fieldDay:
            "%E sends the class and section, like 1D EMA, in one frame."
        case .rttyRoundup:
            "%E sends 599 and the state or province, or the serial number for DX. Typed messages have their serials canonicalised: 599 05 goes out as 599 005 in one frame."
        }
    }

    private func macros(_ model: Bindable<AppModel>) -> some View {
        Section {
            ForEach(0..<8, id: \.self) { index in
                HStack {
                    Text(model.wrappedValue.preferences.macroLabels[index])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.teal)
                        .frame(width: 92, alignment: .leading)
                    TextField(defaultTemplates(model.wrappedValue.preferences)[index], text: model.preferences.macros[index])
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .monospaced()
                }
            }
            Button("Restore defaults") {
                model.wrappedValue.preferences.macros = defaultTemplates(model.wrappedValue.preferences)
            }
        } header: {
            Text(model.wrappedValue.preferences.contestMode ? "Quick messages (contest)" : "Quick messages")
        } footer: {
            Text(model.wrappedValue.preferences.contestMode
                 ? "%M is your call, %H the station you are working, %Q the next one, %E the exchange, %N the serial number, %G your grid. These are WSJT-X's F1 to F8 in the same order. The eight standard templates go out as compact native frames; anything else is sent as text."
                 : "%M is your call, %H the station you are working, %G your grid. Calls, grids and the control phrases pack into single frames; anything else goes as text at five characters a frame.")
        }
    }

    @State private var qrzKey = SecretStore().load(.qrzLogbookKey) ?? ""
    @State private var qrzStatus: String?

    private func logging(_ model: Bindable<AppModel>) -> some View {
        Section {
            Toggle("Upload to QRZ", isOn: model.preferences.logsToQRZ)
                .onChange(of: model.wrappedValue.preferences.logsToQRZ) { _, on in
                    if on { model.wrappedValue.uploadPending() }
                }
            if model.wrappedValue.preferences.logsToQRZ {
                SecureField("Logbook API key", text: $qrzKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: qrzKey) { _, key in
                        SecretStore().save(key, for: .qrzLogbookKey)
                        qrzStatus = nil
                    }
                Button(qrzStatus ?? "Check key") {
                    Task {
                        do {
                            let status = try await QRZLogbookClient().status(key: qrzKey)
                            qrzStatus = "OK: \(status["COUNT"] ?? "?") contacts in \(status["BOOK_NAME"] ?? "the logbook")"
                            model.wrappedValue.uploadPending()
                        } catch {
                            qrzStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                .disabled(qrzKey.isEmpty)
            }
        } header: {
            Text("Logging")
        } footer: {
            Text("Contacts are written to the log on the phone first and uploaded afterwards, so one is never lost to a dead connection. The key is the logbook's API key from its settings page at qrz.com; it needs an XML subscription. The Log tab marks what has been uploaded.")
        }
    }

    private func defaultTemplates(_ preferences: Preferences) -> [String] {
        preferences.contestMode ? NativeMacro.defaultTemplates : NativeMacro.casualTemplates
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            LabeledContent("Mode", value: "JTTY, 4-GFSK 31.25 baud")
            LabeledContent("Frame", value: "1.888 s, 127 Hz")
            Link("JTTY in WSJT-X", destination: URL(string: "https://wsjtx.github.io/wsjtx/")!)
        } header: {
            Text("About")
        } footer: {
            Text("JTTY is a mode of the WSJT development group, by Joe Taylor K1JT and colleagues. This app is an independent implementation of the published protocol. Transmit is keyed by VOX; there is no CAT or PTT control.")
        }
    }
}
