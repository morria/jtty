import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// `-tab log` or `-tab settings` on a debug launch opens that tab.
    private static var initialTab: Int {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-tab"), index + 1 < CommandLine.arguments.count {
            return ["operate", "log", "settings"].firstIndex(of: CommandLine.arguments[index + 1]) ?? 0
        }
        #endif
        return 0
    }

    var body: some View {
        Group {
            if model.preferences.hasCompletedSetup {
                tabs
            } else {
                OnboardingView()
            }
        }
        .animation(.smooth, value: model.preferences.hasCompletedSetup)
        .tint(Palette.teal)
        .onAppear { model.selectedTab = Self.initialTab }
        .onChange(of: scenePhase) { _, phase in
            model.isForeground = phase == .active
            if phase == .active { model.uploadPending() }
        }
        // A message for us: the one thing worth a tap on the wrist.
        .sensoryFeedback(.success, trigger: model.repliesToMe)
        .alert("Upload contacts to QRZ?", isPresented: Binding(get: { model.offersQRZ }, set: { model.offersQRZ = $0 })) {
            Button("Set up in Settings") { model.selectedTab = 2 }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Each logged contact can go straight to your QRZ logbook. It needs the logbook's API key, which is on its settings page at qrz.com, and an XML subscription.")
        }
        .alert(
            model.errorMessage ?? "",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            OperateView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                .badge(model.unreadConversations)
                .tag(0)
            LogView()
                .tabItem { Label("Log", systemImage: "book.closed") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
    }
}

/// First launch: the one thing nothing works without, and the grid for the
/// grid macro.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var callsign = ""
    @State private var grid = ""
    @State private var locator = GridLocator()
    @FocusState private var focus: Field?

    private enum Field { case callsign, grid }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Callsign", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .callsign)
                        .submitLabel(.next)
                        .onSubmit { focus = .grid }
                    HStack {
                        TextField("Grid square", text: $grid)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .grid)
                        Button {
                            focus = nil
                            locator.locate { grid = $0 }
                        } label: {
                            if locator.isLocating { ProgressView() } else { Label("Locate", systemImage: "location").font(.footnote.weight(.semibold)) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(locator.isLocating)
                    }
                } header: {
                    Text("Your station")
                } footer: {
                    if let error = locator.errorMessage {
                        Text(error).foregroundStyle(Palette.salmon)
                    } else {
                        Text("Your callsign goes in every CQ and every reply. The grid is only used by the grid macro.")
                    }
                }
                Section {
                    LabeledContent("Wiring", value: "Audio interface")
                } footer: {
                    Text("JTTY listens through the audio input and transmits through the audio output. Connect a wired interface between the phone and the radio's data port, and key the transmitter with VOX.")
                }
            }
            .navigationTitle("JTTY")
            .dismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        var preferences = model.preferences
                        preferences.callsign = callsign
                        preferences.grid = grid
                        preferences.hasCompletedSetup = true
                        model.preferences = preferences.normalized()
                    }
                    .disabled(callsign.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { focus = .callsign }
    }
}
