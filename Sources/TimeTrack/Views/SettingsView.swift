import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var teamleader: Teamleader
    @AppStorage("idleMinutes") private var idleMinutes = 5
    @AppStorage("roundTo") private var roundTo = 15

    @State private var clientId = Teamleader.shared.clientId
    @State private var clientSecret = Teamleader.shared.clientSecret
    @State private var connecting = false
    @State private var error: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Toestemming") {
                LabeledContent("Venstertitels uitlezen") {
                    if tracker.hasAccessibility {
                        Label("Toegestaan", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Toestemming geven…") { tracker.requestAccessibility() }
                    }
                }
                if !tracker.hasAccessibility {
                    Text("Zet TimeTrack aan in Systeeminstellingen → Privacy en beveiliging → Toegankelijkheid. Zonder deze toestemming ziet TimeTrack enkel de programmanaam.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Teamleader") {
                if let user = teamleader.userName, teamleader.isConnected {
                    LabeledContent("Verbonden als", value: user)
                    LabeledContent("Werksoorten", value: "\(teamleader.workTypes.count)")
                    HStack {
                        Button("Gegevens vernieuwen") { run { try await teamleader.refreshProfile() } }
                        Button("Verbinding verbreken", role: .destructive) { teamleader.disconnect() }
                    }
                } else {
                    TextField("Client ID", text: $clientId)
                    SecureField("Client secret", text: $clientSecret)
                    LabeledContent("Redirect URI") {
                        Text(Teamleader.redirectURI).textSelection(.enabled).font(.body.monospaced())
                    }
                    Button(connecting ? "Wachten op Teamleader…" : "Verbinden met Teamleader") {
                        teamleader.clientId = clientId
                        teamleader.clientSecret = clientSecret
                        run { try await teamleader.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting || clientId.isEmpty || clientSecret.isEmpty)
                    Text("Maak een integratie op marketplace.focus.teamleader.eu/build en gebruik bovenstaande Redirect URI. Je browser opent om toegang te geven.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section("Registratie") {
                Stepper("Inactief na \(idleMinutes) min zonder muis/toetsenbord", value: $idleMinutes, in: 1...60)
                Picker("Registraties afronden op", selection: $roundTo) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { Text($0 == 1 ? "1 minuut" : "\($0) minuten").tag($0) }
                }
                Toggle("Starten bij aanmelden", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            self.error = "Starten bij aanmelden: \(error.localizedDescription)"
                        }
                    }
                Toggle("Registratie gepauzeerd", isOn: $tracker.paused)
            }

            Section("Gegevens") {
                LabeledContent("Opgeslagen in") {
                    Text(Database.directory.path).textSelection(.enabled).font(.caption)
                }
                Button("Toon in Finder") { NSWorkspace.shared.open(Database.directory) }
                Text("Alle activiteit blijft op deze Mac. Enkel registraties die je zelf verstuurt gaan naar Teamleader.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        connecting = true
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}
