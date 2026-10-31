import AppKit
import SwiftUI

/// Laat schermen weten dat regels of registraties gewijzigd zijn.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var revision = 0
    func changed() { revision += 1 }
}

@main
struct TimeTrackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var tracker = Tracker.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(open: { delegate.showMainWindow() }).environmentObject(tracker)
        } label: {
            Image(systemName: tracker.paused ? "pause.circle" : "clock.fill")
        }
    }
}

/// Het hoofdvenster wordt zelf beheerd: het opent bij de eerste start, via het menubalk-icoon of een melding,
/// maar niet bij elke aanmelding.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        Tracker.shared.start()
        Reminder.shared.start()
        Task { @MainActor in
            Updater.shared.startPeriodicChecks()
            if !UserDefaults.standard.bool(forKey: "onboarded") { self.showMainWindow() }
        }
    }

    /// timetrack://callback?... na het aanmelden bij Teamleader via tools.mtea.be
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { Teamleader.shared.handleOpenURL(url) }
            self.showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in self.showMainWindow() }
        return true
    }

    @MainActor
    func showMainWindow() {
        if window == nil {
            let root = MainView()
                .environmentObject(Tracker.shared)
                .environmentObject(Teamleader.shared)
                .environmentObject(AppModel.shared)
                .environmentObject(DayModel.shared)
                .environmentObject(CalendarSource.shared)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "TimeTrack"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 1120, height: 780))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("TimeTrackMain")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuContent: View {
    @EnvironmentObject var tracker: Tracker
    let open: () -> Void

    var body: some View {
        Text(tracker.statusText.count > 60 ? String(tracker.statusText.prefix(60)) + "…" : tracker.statusText)
        if !tracker.hasAccessibility {
            Text("⚠︎ Geen toegang tot venstertitels")
        }
        Divider()
        Button("Voorstel van vandaag…") {
            Task { @MainActor in DayModel.shared.day = Date() }
            open()
        }
        .keyboardShortcut("t")
        Button(tracker.paused ? "Hervat registratie" : "Pauzeer registratie") { tracker.paused.toggle() }
        Divider()
        Button("Stop TimeTrack") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MainView: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var teamleader: Teamleader
    @StateObject private var updater = Updater.shared
    @AppStorage("onboarded") private var onboarded = false
    @State private var tab = 0
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            if updater.updateAvailable, let latest = updater.latest {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Nieuwe versie \(latest) beschikbaar.")
                    Spacer()
                    Button(updater.installing ? "Bezig…" : "Nu bijwerken") { Task { await updater.install() } }
                        .disabled(updater.installing)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
            }
            TabView(selection: $tab) {
                TodayView().tabItem { Label("Vandaag", systemImage: "calendar.day.timeline.left") }.tag(0)
                WeekView(tab: $tab).tabItem { Label("Week", systemImage: "chart.bar") }.tag(1)
                RulesView().tabItem { Label("Correcties", systemImage: "wand.and.stars") }.tag(2)
                SettingsView().tabItem { Label("Instellingen", systemImage: "gearshape") }.tag(3)
            }
            .padding(.top, 4)
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .onAppear { showOnboarding = !onboarded }
    }
}
