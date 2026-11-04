import AppKit
import SwiftUI

/// Laat schermen weten dat regels of registraties gewijzigd zijn.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var revision = 0
    /// Actief tabblad van het hoofdvenster (0 Vandaag, 1 Week, 2 Correcties, 3 Instellingen).
    @Published var tab = 0
    func changed() { revision += 1 }
}

@main
struct TimeTrackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var tracker = Tracker.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(open: { delegate.showMainWindow() })
                .environmentObject(tracker)
                .environmentObject(Teamleader.shared)
        } label: {
            Image(systemName: tracker.paused ? "pause.circle" : (tracker.hasAccessibility ? "clock.fill" : "clock.badge.exclamationmark"))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Het hoofdvenster wordt zelf beheerd: het opent bij de eerste start, via het menubalk-icoon of een melding,
/// maar niet bij elke aanmelding.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Automatisch starten staat standaard aan (eenmalig bij de eerste start).
        if !UserDefaults.standard.bool(forKey: "launchAtLoginAsked") {
            UserDefaults.standard.set(true, forKey: "launchAtLoginAsked")
            try? LaunchAtLogin.set(true)
        }
        Tracker.shared.start()
        Reminder.shared.start()
        Task { @MainActor in CallWatcher.shared.start() }
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
            w.delegate = self
            window = w
        }
        // Zolang het venster open is, staat TimeTrack ook in het Dock en in ⌘-Tab (makkelijk terug te vinden,
        // ook als het menubalk-icoon achter de inkeping van het scherm verdwijnt).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Paneel onder het klokje in de menubalk: je dag in één oogopslag, en registreren met één klik.
struct MenuContent: View {
    @EnvironmentObject var tracker: Tracker
    @ObservedObject private var model = DayModel.menu
    @ObservedObject private var teamleader = Teamleader.shared
    let open: () -> Void

    private var ready: [Proposal] { model.plan.proposals.filter { $0.match.isAssigned } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(tracker.paused ? Color.orange : tracker.hasAccessibility ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(tracker.paused ? "Gepauzeerd" : tracker.statusText)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if !tracker.hasAccessibility {
                Button {
                    tracker.requestAccessibility()
                    SystemSettings.open("Privacy_Accessibility")
                } label: {
                    Label("Geen toegang tot vensters – toestemming geven", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            HStack(spacing: 8) {
                miniStat("Gewerkt", model.plan.worked, .blue)
                miniStat("In Teamleader", model.plan.registeredSeconds, .green)
                miniStat("Te registreren", model.plan.proposedSeconds, .orange)
            }

            if !model.plan.proposals.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.plan.proposals.prefix(5)) { p in
                        HStack(spacing: 10) {
                            Avatar(name: p.match.isAssigned ? p.match.companyName : "", size: 24)
                            Text(p.match.isAssigned ? p.match.companyName : "Niet herkend").lineLimit(1)
                            Spacer()
                            Text(formatDuration(p.seconds)).monospacedDigit().foregroundStyle(.secondary)
                            if p.match.isAssigned {
                                Button {
                                    Task { _ = await model.register(p) }
                                } label: { Image(systemName: "checkmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.green)
                                .disabled(!model.canRegister)
                                .help("Registreer in Teamleader")
                            }
                        }
                        .font(.callout)
                    }
                    if model.plan.proposals.count > 5 {
                        Text("en nog \(model.plan.proposals.count - 5)…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            } else if model.plan.worked >= 60 {
                Label("Alles staat in Teamleader", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                Button {
                    AppModel.shared.tab = 0
                    DayModel.shared.day = Date()
                    open()
                } label: { Label("Open TimeTrack", systemImage: "macwindow") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("t")
                if ready.count > 1 {
                    Button("Alles registreren") { Task { await model.registerAll(ready) } }
                        .disabled(!model.canRegister)
                }
                Spacer()
                Menu {
                    Button(tracker.paused ? "Hervat registratie" : "Pauzeer registratie") { tracker.paused.toggle() }
                    Button("Instellingen…") {
                        AppModel.shared.tab = 3
                        open()
                    }
                    Divider()
                    Button("Stop TimeTrack") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            model.day = Date()
            await model.reload()
        }
    }

    private func miniStat(_ title: String, _ seconds: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(formatDuration(seconds)).font(.system(.headline, design: .rounded)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.1)))
    }
}

/// Hoofdvenster met zijbalk.
struct MainView: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var teamleader: Teamleader
    @StateObject private var updater = Updater.shared
    @AppStorage("onboarded") private var onboarded = false
    @ObservedObject private var appModel = AppModel.shared
    @State private var showOnboarding = false

    private let sections: [(tag: Int, title: String, icon: String)] = [
        (0, "Vandaag", "sun.max.fill"), (1, "Week", "chart.bar.fill"),
        (2, "Correcties", "wand.and.stars"), (3, "Instellingen", "gearshape.fill"),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Int?>(get: { appModel.tab }, set: { appModel.tab = $0 ?? 0 })) {
                ForEach(sections, id: \.tag) { s in
                    Label(s.title, systemImage: s.icon).tag(s.tag as Int?)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if updater.updateAvailable, let latest = updater.latest {
                    Banner(icon: "arrow.down.circle.fill", tint: .accentColor, text: "Nieuwe versie \(latest) beschikbaar.") {
                        Button(updater.installing ? "Bezig…" : "Nu bijwerken") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.installing)
                    }
                    .padding([.horizontal, .top], 16)
                }
                switch appModel.tab {
                case 1: WeekView(tab: $appModel.tab)
                case 2: RulesView()
                case 3: SettingsView()
                default: TodayView()
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
        .onAppear { showOnboarding = !onboarded }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(tracker.paused ? Color.orange : tracker.hasAccessibility ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(tracker.paused ? "Gepauzeerd" : tracker.hasAccessibility ? "Registreert" : "Geen toegang")
                    .font(.caption)
            }
            Text(teamleader.userName.map { "Teamleader: \($0)" } ?? "Teamleader niet verbonden")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Label("Enkel jij ziet je activiteit", systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
