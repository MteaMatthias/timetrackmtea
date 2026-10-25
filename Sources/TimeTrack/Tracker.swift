import AppKit
import ApplicationServices

/// Registreert elke paar seconden het actieve programma en venster.
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
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sleeping = true }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sleeping = false }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
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

    private func tick() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibility { hasAccessibility = trusted }

        let now = Date().timeIntervalSince1970
        defer { lastTick = now }
        if paused { statusText = "Gepauzeerd"; lastKey = nil; return }
        if sleeping || screenLocked { statusText = "Scherm vergrendeld"; lastKey = nil; return }
        guard let window = Self.activeWindow() else { statusText = "Geen actief venster"; lastKey = nil; return }

        let idle = Self.idleSeconds()
        let isIdle = idle >= idleAfter
        let app = isIdle ? Store.idleApp : window.app
        let title = isIdle ? "" : window.title
        let key = app + "\u{1}" + title
        statusText = isIdle ? "Inactief" : (title.isEmpty ? app : "\(app) — \(title)")

        // Bij een te grote kloof (slaapstand, pauze, vastgelopen timer) begint een nieuw blok.
        let contiguous = lastKey != nil && now - lastTick <= interval * 3
        let db = Database.shared
        if contiguous && key == lastKey {
            db.run("UPDATE activity SET end=? WHERE id=?", now, lastId)
        } else {
            var start = contiguous ? lastTick : now
            if isIdle && contiguous {
                // De inactieve minuten tellen niet mee voor het vorige venster.
                start = max(lastStart, now - idle)
                db.run("UPDATE activity SET end=? WHERE id=?", start, lastId)
            }
            lastId = db.run("INSERT INTO activity(start, end, app, bundle, title) VALUES (?,?,?,?,?)",
                            start, now, app, isIdle ? "" : window.bundle, title)
            lastStart = start
        }
        lastKey = key
    }

    /// Programma via NSWorkspace; venstertitel via de Accessibility-API (vereist toestemming).
    static func activeWindow() -> (app: String, bundle: String, title: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var title = ""
        let element = AXUIElementCreateApplication(app.processIdentifier)
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
}
