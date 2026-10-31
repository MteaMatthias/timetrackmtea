import AppKit
import ApplicationServices
import IOKit.pwr_mgt

/// Registreert elke paar seconden het actieve programma, de venstertitel en (bij browsers) het domein.
/// Opeenvolgende metingen van hetzelfde venster worden één blok in de database.
final class Tracker: ObservableObject {
    static let shared = Tracker()

    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            lastKey = nil
        }
    }
    @Published private(set) var statusText = "Opstarten…"
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()

    let interval: TimeInterval = 5
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var sleeping = false
    private var screenLocked = false
    private var lastId: Int64 = 0
    private var lastKey: String?
    private var lastStart: Double = 0
    private var lastTick: Double = 0

    private var idleAfter: Double {
        let minutes = UserDefaults.standard.integer(forKey: "idleMinutes")
        return Double(minutes > 0 ? minutes : 5) * 60
    }

    func start() {
        guard timer == nil else { return }
        // Zonder dit zet macOS een app zonder zichtbaar venster in "App Nap" en vallen metingen weg.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Tijdsregistratie")
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = true
                self?.closeBlock()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sleeping = false }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.closeBlock()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
        }
        tick()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
    }

    /// Bij vergrendelen of slaapstand: de tijd sinds de laatste muis-/toetsenbordactie telt niet als werk.
    private func closeBlock() {
        guard lastKey != nil else { return }
        trimIdle(since: Date().timeIntervalSince1970 - min(Self.idleSeconds(), idleAfter))
        lastKey = nil
    }

    /// Kort alle blokken in die na `since` liepen (ook titelwissels zonder invoer, bv. ongelezen-tellers).
    private func trimIdle(since: Double) {
        let db = Database.shared
        db.run("UPDATE activity SET end = max(start, ?) WHERE end > ? AND app != ?", since, since, Store.idleApp)
        db.run("DELETE FROM activity WHERE end <= start")
    }

    private func tick() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibility { hasAccessibility = trusted }

        let now = Date().timeIntervalSince1970
        defer { lastTick = now }
        if paused { statusText = "Gepauzeerd"; lastKey = nil; return }
        if sleeping || screenLocked { statusText = "Scherm vergrendeld"; lastKey = nil; return }
        guard let window = Self.activeWindow() else { statusText = "Geen actief venster"; lastKey = nil; return }

        // Tijd in TimeTrack zelf (voorstellen nakijken) hoort bij het vorige blok.
        if window.bundle == Bundle.main.bundleIdentifier, lastKey != nil {
            Database.shared.run("UPDATE activity SET end=? WHERE id=?", now, lastId)
            return
        }

        let idle = Self.idleSeconds()
        // Een videocall of presentatie zonder muis/toetsenbord is geen inactiviteit.
        let isIdle = idle >= idleAfter && !Self.displaySleepPrevented()
        let app = isIdle ? Store.idleApp : window.app
        let title = isIdle ? "" : window.title
        let host = isIdle ? "" : (Browser.currentHost(bundleId: window.bundle) ?? "")
        let key = [app, title, host].joined(separator: "\u{1}")
        statusText = isIdle ? "Inactief" : [app, host.isEmpty ? title : host].filter { !$0.isEmpty }.joined(separator: " — ")

        // Bij een te grote kloof (slaapstand, pauze, vastgelopen timer) begint een nieuw blok.
        let contiguous = lastKey != nil && now - lastTick <= interval * 3
        let db = Database.shared
        if contiguous && key == lastKey {
            db.run("UPDATE activity SET end=? WHERE id=?", now, lastId)
        } else {
            var start = contiguous ? lastTick : now
            if isIdle && contiguous {
                start = max(lastStart, now - idle)
                trimIdle(since: start)
            }
            lastId = db.run("INSERT INTO activity(start, end, app, bundle, title, host) VALUES (?,?,?,?,?,?)",
                            start, now, app, isIdle ? "" : window.bundle, title, host)
            lastStart = start
        }
        lastKey = key
    }

    /// Programma via NSWorkspace; venstertitel via de Accessibility-API (vereist toestemming).
    static func activeWindow() -> (app: String, bundle: String, title: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var title = ""
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Een vastgelopen programma mag TimeTrack niet laten haperen (standaard wacht macOS 6 s).
        AXUIElementSetMessagingTimeout(element, 0.5)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                title = value as? String ?? ""
            }
        }
        return (app.localizedName ?? "?", app.bundleIdentifier ?? "", title)
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// True wanneer een programma (Teams, Zoom, Meet in de browser, Keynote…) het scherm wakker houdt.
    static func displaySleepPrevented() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }
}

/// Leest het domein van het actieve tabblad in gangbare browsers (vraagt eenmalig toestemming per browser).
enum Browser {
    private static let scripts: [String: String] = [
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to get URL of front document",
        "com.google.Chrome": "tell application id \"com.google.Chrome\" to get URL of active tab of front window",
        "com.microsoft.edgemac": "tell application id \"com.microsoft.edgemac\" to get URL of active tab of front window",
        "com.brave.Browser": "tell application id \"com.brave.Browser\" to get URL of active tab of front window",
        "company.thebrowser.Browser": "tell application id \"company.thebrowser.Browser\" to get URL of active tab of front window",
        "com.vivaldi.Vivaldi": "tell application id \"com.vivaldi.Vivaldi\" to get URL of active tab of front window",
    ]
    private static var compiled: [String: NSAppleScript] = [:]

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "browserDisabled") }

    /// Enkel het domein (bv. "janssen.be") wordt bewaard, nooit het volledige adres.
    static func currentHost(bundleId: String) -> String? {
        guard isEnabled, let source = scripts[bundleId] else { return nil }
        let script = compiled[bundleId] ?? NSAppleScript(source: source)
        compiled[bundleId] = script
        var error: NSDictionary?
        guard let url = script?.executeAndReturnError(&error).stringValue,
              let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
