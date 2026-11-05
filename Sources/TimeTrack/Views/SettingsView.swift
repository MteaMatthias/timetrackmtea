import AppKit
import EventKit
import ServiceManagement
import SwiftUI

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum SystemSettings {
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Alles wat ingesteld moet zijn, met één knop per stap. Gebruikt in de eerste-start-wizard en in Instellingen.
struct SetupChecklist: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var teamleader: Teamleader
    @EnvironmentObject var calendar: CalendarSource
    @AppStorage("browserDisabled") private var browserDisabled = false
    @AppStorage("reminderEnabled") private var reminderEnabled = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var browserPermission = Browser.Permission.unknown
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CheckRow(done: tracker.hasAccessibility, title: "1. Vensters herkennen",
                     detail: tracker.hasAccessibility
                        ? "TimeTrack ziet welk document of venster actief is."
                        : "Zet TimeTrack aan bij Toegankelijkheid (macOS vraagt hiervoor je Mac-wachtwoord; heb je geen beheerdersrechten, vraag het dan aan wie je Mac beheert). Staat het er al maar werkt het niet? Verwijder het met – en voeg het opnieuw toe.") {
                if !tracker.hasAccessibility {
                    Button("Toestemming geven…") { tracker.requestAccessibility() }
                }
            }
            Divider()
            CheckRow(done: teamleader.isConnected, title: "2. Teamleader",
                     detail: teamleader.isConnected
                        ? "Verbonden als \(teamleader.userName ?? "?") · \(teamleader.companyCount) klanten herkenbaar"
                        : "Meld je aan met je eigen Teamleader-account. Je klanten worden dan automatisch herkend.") {
                if teamleader.isConnected {
                    Button("Ontkoppelen", role: .destructive) { teamleader.disconnect() }
                } else if connecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("Annuleer") { teamleader.cancelConnect() }
                    }
                } else {
                    Button("Verbinden met Teamleader") { connect() }.buttonStyle(.borderedProminent)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.leading, 40)
            }
            Divider()
            CheckRow(done: calendar.authorized, title: "3. Agenda (aanbevolen)",
                     detail: "Vergaderingen tellen als werk, ook als je ondertussen niets aanraakt. Werkt met iCloud-, Google- en Microsoft-agenda's die op deze Mac staan.") {
                if !calendar.authorized {
                    Button("Agenda koppelen") {
                        Task {
                            await calendar.requestAccess()
                            if !calendar.authorized { SystemSettings.open("Privacy_Calendars") }
                        }
                    }
                }
            }
            Divider()
            CheckRow(done: !browserDisabled && browserPermission != .denied, title: "4. Websites",
                     detail: browserPermission == .denied
                        ? "Je browser gaf TimeTrack geen toestemming, dus websites worden niet herkend. Zet TimeTrack aan onder Systeeminstellingen → Privacy en beveiliging → Automatisering."
                        : "Het domein van de website die je bekijkt (bv. klantx.be) helpt de klant herkennen. Bij het eerste gebruik vraagt macOS per browser om toestemming: klik op OK. Enkel het domein wordt bewaard.") {
                HStack {
                    if browserPermission == .denied {
                        Button("Toestemming geven…") { SystemSettings.open("Privacy_Automation") }
                    }
                    Toggle("", isOn: Binding(get: { !browserDisabled }, set: { browserDisabled = !$0 })).labelsHidden()
                }
            }
            Divider()
            CheckRow(done: launchAtLogin, title: "5. Automatisch starten",
                     detail: "TimeTrack start mee op wanneer je je Mac opent, zodat er niets verloren gaat.") {
                Toggle("", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { on in
                        UserDefaults.standard.set(!on, forKey: "launchAtLoginDisabled")
                        do { try LaunchAtLogin.set(on) } catch { self.error = "Automatisch starten: \(error.localizedDescription)" }
                    }
            }
            Divider()
            CheckRow(done: reminderEnabled, title: "6. Dagelijkse melding",
                     detail: "Rond 17 u krijg je een melding als er nog tijd te registreren is.") {
                Toggle("", isOn: $reminderEnabled).labelsHidden()
                    .onChange(of: reminderEnabled) { on in
                        if on { Task { await Reminder.shared.requestPermission() } }
                    }
            }
        }
        .onAppear { browserPermission = Browser.automationPermission() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            browserPermission = Browser.automationPermission()
        }
    }

    private func connect() {
        connecting = true
        error = nil
        Task {
            do {
                try await teamleader.connect()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

/// Wizard bij de eerste start.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welkom bij TimeTrack").font(.largeTitle.weight(.bold))
            Text("TimeTrack houdt bij waar je aan werkt en stelt elke dag voor wat je in Teamleader kan registreren. Je bevestigt met één klik.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Privé: wat je doet (programma's, websites, oproepen) en je voorstellen blijven enkel op deze Mac. Niemand anders ziet ze: geen collega's, geen beheerder, ook niet tools.mtea.be. Pas wanneer jij een voorstel registreert, komt die registratie op jouw naam in Teamleader. Daar zijn ze zichtbaar volgens de rechten in Teamleader (zoals elke tijdsregistratie die je zelf invult).", systemImage: "lock.fill")
                .font(.callout)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.1)))
                .fixedSize(horizontal: false, vertical: true)
            SetupChecklist()
            HStack {
                Spacer()
                Button("Klaar") {
                    onboarded = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 720)
        .onAppear {
            // De dagelijkse melding staat standaard aan: meteen om toestemming vragen.
            Task { await Reminder.shared.requestPermission() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var teamleader: Teamleader
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var calendar: CalendarSource
    @EnvironmentObject var appModel: AppModel
    @State private var excluded: [Company] = []
    @StateObject private var updater = Updater.shared
    @AppStorage("idleMinutes") private var idleMinutes = 5
    @AppStorage("roundTo") private var roundTo = 5
    @AppStorage("billRoundTo") private var billRoundTo = 10
    @AppStorage("calendarDisabled") private var calendarDisabled = false
    @AppStorage("bundlePerClient") private var bundlePerClient = true
    @AppStorage("callPromptsDisabled") private var callPromptsDisabled = false
    @State private var flowTest: String?
    @State private var chatTest: String?
    @State private var chatCountdown = 0

    /// 5 seconden om Claude (of ChatGPT) vooraan te zetten; dan lezen wat TimeTrack daar ziet.
    private func testChat() async {
        chatTest = nil
        for second in stride(from: 2, to: 0, by: -1) {
            chatCountdown = second
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        chatCountdown = 0
        chatTest = await AIChatReader.diagnose()
        NSApp.activate(ignoringOtherApps: true)
    }
    @State private var confirmWipe = false
    @State private var portalURL = ""
    @State private var useCustomClient = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Instellen") {
                SetupChecklist()
            }

            Section("Voorstellen") {
                Stepper("Inactief na \(idleMinutes) min zonder muis of toetsenbord", value: $idleMinutes, in: 2...30)
                Toggle("Per klant één voorstel per dag (alle blokken samengeteld)", isOn: $bundlePerClient)
                    .onChange(of: bundlePerClient) { _ in appModel.changed() }
                Picker("Duur afronden op", selection: $roundTo) {
                    Text("1 minuut").tag(1)
                    Text("5 minuten").tag(5)
                    Text("15 minuten").tag(15)
                }
                Picker("In Teamleader naar boven afronden op", selection: $billRoundTo) {
                    Text("1 minuut").tag(1)
                    Text("5 minuten").tag(5)
                    Text("10 minuten").tag(10)
                    Text("15 minuten").tag(15)
                    Text("30 minuten").tag(30)
                }
                .onChange(of: billRoundTo) { _ in appModel.changed() }
                Text("Elke registratie gaat naar boven afgerond naar Teamleader: 3 min bellen wordt bij 10 minuten 10 min.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Agenda gebruiken", isOn: Binding(get: { !calendarDisabled }, set: { calendarDisabled = !$0 }))
                if calendar.authorized && !calendarDisabled {
                    DisclosureGroup("Welke agenda's tellen mee?") {
                        Text("Zet agenda's van collega's, gedeelde of privé-agenda's uit.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(calendar.calendars, id: \.calendarIdentifier) { cal in
                            Toggle(isOn: Binding(
                                get: { !calendar.excludedCalendars.contains(cal.calendarIdentifier) },
                                set: { on in
                                    var set = calendar.excludedCalendars
                                    if on { set.remove(cal.calendarIdentifier) } else { set.insert(cal.calendarIdentifier) }
                                    calendar.excludedCalendars = set
                                    appModel.changed()
                                })) {
                                Text("\(cal.title)  ").foregroundColor(Color(cal.color))
                                    + Text(cal.source.title).foregroundColor(.secondary).font(.caption)
                            }
                        }
                    }
                }
                Toggle("Bijhouden gepauzeerd", isOn: $tracker.paused)
            }

            Section("Oproepen en meetings") {
                Toggle("Bij een oproep (Flow) of meeting vragen voor welke klant", isOn: Binding(
                    get: { !callPromptsDisabled }, set: { callPromptsDisabled = !$0 }))
                Text("Teams, Zoom, Google Meet, Loom, FaceTime en Webex worden herkend; bij Flow ook het nummer. Het gesprek komt in je dagvoorstel. Je antwoord wordt onthouden voor dat nummer of die meeting.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Test de herkenning in Flow") { flowTest = Self.flowDiagnosis() }
                if let flowTest {
                    Text(flowTest).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            Section("AI-chats (Claude, ChatGPT)") {
                Text("TimeTrack leest de titel van het gesprek en zoekt er een klantnaam in, zodat je chat bij de juiste klant komt. Er wordt niets van het gesprek bewaard behalve die titel.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(chatCountdown > 0 ? "Even geduld… \(chatCountdown)" : "Test: wat leest TimeTrack in Claude?") {
                    Task { await testChat() }
                }
                .disabled(chatCountdown > 0)
                if let chatTest {
                    Text(chatTest).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Kopieer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chatTest, forType: .string)
                    }
                }
            }

            if !excluded.isEmpty {
                Section("Niet als klant herkend") {
                    Text("Leveranciers of tools die je met \"Geen klant?\" uitsloot.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(excluded) { company in
                        HStack {
                            Text(company.name)
                            Spacer()
                            Button("Terugzetten") {
                                Matcher.exclude(companyId: company.id, false)
                                loadExcluded()
                                appModel.changed()
                            }
                        }
                    }
                }
            }

            Section("Updates") {
                LabeledContent("Versie", value: updater.current)
                if updater.updateAvailable, let latest = updater.latest {
                    HStack {
                        Text("Versie \(latest) is beschikbaar.")
                        Spacer()
                        Button(updater.installing ? "Bezig met bijwerken…" : "Nu bijwerken") {
                            Task { await updater.install() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.installing)
                    }
                } else {
                    Button("Controleer op updates") { Task { await updater.check() } }
                }
                if let error = updater.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }

            Section("Gegevens") {
                LabeledContent("Opgeslagen in") {
                    Text(Database.directory.path).textSelection(.enabled).font(.caption)
                }
                Button("Toon in Finder") { NSWorkspace.shared.open(Database.directory) }
                Button("Wis mijn activiteit…", role: .destructive) { confirmWipe = true }
                    .confirmationDialog("Alle bijgehouden activiteit op deze Mac wissen?", isPresented: $confirmWipe) {
                        Button("Wis activiteit", role: .destructive) {
                            Store.wipeActivity()
                            appModel.changed()
                        }
                    } message: {
                        Text("Je registraties in Teamleader, je correcties en je instellingen blijven bewaard.")
                    }
                Text("Activiteit ouder dan 90 dagen wordt automatisch gewist.").font(.caption).foregroundStyle(.secondary)
                Label("Privé: wat je doet (programma's, websites, oproepen) en je voorstellen blijven enkel op deze Mac. Niemand anders ziet ze: geen collega's, geen beheerder, ook niet tools.mtea.be. Pas wanneer jij een voorstel registreert, komt die registratie op jouw naam in Teamleader. Daar zijn ze zichtbaar volgens de rechten in Teamleader (zoals elke tijdsregistratie die je zelf invult).", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Geavanceerd", isExpanded: $showAdvanced) {
                    TextField("Portaal", text: $portalURL, prompt: Text(Teamleader.defaultPortal))
                        .onSubmit { teamleader.portalURL = portalURL.isEmpty ? Teamleader.defaultPortal : portalURL }
                    Toggle("Eigen Teamleader-integratie gebruiken", isOn: $useCustomClient)
                        .onChange(of: useCustomClient) { teamleader.useCustomClient = $0 }
                    if useCustomClient {
                        TextField("Client ID", text: $clientId)
                            .onChange(of: clientId) { teamleader.clientId = $0 }
                        SecureField("Client secret", text: $clientSecret)
                            .onSubmit { teamleader.clientSecret = clientSecret }
                        Text("Redirect URI: \(Teamleader.customRedirectURI)")
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadExcluded()
            portalURL = teamleader.portalURL
            useCustomClient = teamleader.useCustomClient
            clientId = teamleader.clientId
        }
        .onDisappear {
            if useCustomClient && !clientSecret.isEmpty { teamleader.clientSecret = clientSecret }
        }
        .onChange(of: appModel.revision) { _ in loadExcluded() }
    }

    /// Wat TimeTrack nu in Flow leest (om problemen op te sporen).
    private static func flowDiagnosis() -> String {
        guard let app = FlowReader.app() else { return "Flow is niet geopend." }
        let texts = FlowReader.texts(of: app)
        let result: String
        if let call = FlowReader.parse(texts) {
            result = "Gesprek gevonden: \(call.label) · \(call.detail) · \(call.ringing ? "rinkelt" : "loopt")"
        } else {
            result = "Geen gesprek gevonden (normaal als er nu niemand belt)."
        }
        return result + "\n\(texts.count) teksten gelezen, bv.: " + texts.prefix(40).joined(separator: " | ")
    }

    private func loadExcluded() {
        let ids = Matcher.excludedCompanies
        excluded = Store.companies().filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }
}
