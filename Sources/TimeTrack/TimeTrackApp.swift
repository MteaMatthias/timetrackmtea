import AppKit
import SwiftUI

/// Laat schermen weten dat regels of registraties gewijzigd zijn.
final class AppModel: ObservableObject {
    @Published var revision = 0
    func changed() { revision += 1 }
}

@main
struct TimeTrackApp: App {
    @StateObject private var tracker = Tracker.shared
    @StateObject private var teamleader = Teamleader.shared
    @StateObject private var model = AppModel()

    init() {
        Tracker.shared.start()
    }

    var body: some Scene {
        Window("TimeTrack", id: "main") {
            MainView()
                .environmentObject(tracker)
                .environmentObject(teamleader)
                .environmentObject(model)
        }
        .defaultSize(width: 1100, height: 740)

        MenuBarExtra {
            MenuContent().environmentObject(tracker)
        } label: {
            Image(systemName: tracker.paused ? "pause.circle" : "clock.fill")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var tracker: Tracker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(tracker.statusText.count > 60 ? String(tracker.statusText.prefix(60)) + "…" : tracker.statusText)
        if !tracker.hasAccessibility {
            Text("⚠︎ Geen toegang tot venstertitels")
        }
        Divider()
        Button(tracker.paused ? "Hervat registratie" : "Pauzeer registratie") { tracker.paused.toggle() }
        Button("Open TimeTrack…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Stop TimeTrack") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MainView: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var teamleader: Teamleader
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            DayView().tabItem { Label("Dag", systemImage: "calendar") }.tag(0)
            EntriesView().tabItem { Label("Registraties", systemImage: "list.bullet.rectangle") }.tag(1)
            RulesView().tabItem { Label("Regels", systemImage: "wand.and.stars") }.tag(2)
            SettingsView().tabItem { Label("Instellingen", systemImage: "gearshape") }.tag(3)
        }
        .padding(.top, 4)
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            if !tracker.hasAccessibility || !teamleader.isConnected { tab = 3 }
        }
    }
}
