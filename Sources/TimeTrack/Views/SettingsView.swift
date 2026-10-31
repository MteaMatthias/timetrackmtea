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
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CheckRow(done: tracker.hasAccessibility, title: "1. Vensters herkennen",
                     detail: tracker.hasAccessibility
                        ? "TimeTrack ziet welk document of venster actief is."
                        : "Zet TimeTrack aan bij Toegankelijkheid. Staat het er al maar werkt het niet (na een update)? Verwijder het met – en voeg het opnieuw toe.") {
                if !tracker.hasAccessibility {
                    Button("Toestemming geven…") {
                        tracker.requestAccessibility()
                        SystemSettings.open("Privacy_Accessibility")
                    }
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
            CheckRow(done: !browserDisabled, title: "4. Websites",
                     detail: "Het domein van de website die je bekijkt (bv. klantx.be) helpt de klant herkennen. Bij het eerste gebruik vraagt macOS per browser om toestemming: klik op OK. Enkel het domein wordt bewaard.") {
                Toggle("", isOn: Binding(get: { !browserDisabled }, set: { browserDisabled = !$0 })).labelsHidden()
            }
            Divider()
            CheckRow(done: launchAtLogin, title: "5. Automatisch starten",
                     detail: "TimeTrack start mee op wanneer je je Mac opent, zodat er niets verloren gaat.") {
                Toggle("", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { on in
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
            Text("TimeTrack houdt bij waar je aan werkt en stelt elke dag voor wat je in Teamleader kan registreren. Je bevestigt met één klik. Alles blijft op je Mac; enkel wat je bevestigt gaat naar Teamleader.")
                .foregroundStyle(.secondary)
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
            // Automatisch starten en de dagelijkse melding staan standaard aan.
            if !UserDefaults.standard.bool(forKey: "launchAtLoginAsked") {
                UserDefaults.standard.set(true, forKey: "launchAtLoginAsked")
                try? LaunchAtLogin.set(true)
            }
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
    @AppStorage("calendarDisabled") private var calendarDisabled = false
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
                Picker("Duur afronden op", selection: $roundTo) {
                    Text("1 minuut").tag(1)
                    Text("5 minuten").tag(5)
                    Text("15 minuten").tag(15)
                }
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
                Toggle("Registratie gepauzeerd", isOn: $tracker.paused)
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
                Text("Activiteit, vensters en websites blijven op deze Mac. Enkel wat je zelf registreert gaat naar Teamleader.")
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

    private func loadExcluded() {
        let ids = Matcher.excludedCompanies
        excluded = Store.companies().filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }
}
