import AppKit
import ApplicationServices
import Darwin
import IOKit.pwr_mgt

/// Registreert elke paar seconden het actieve programma, de venstertitel en (bij browsers) het domein.
/// Opeenvolgende metingen van hetzelfde venster worden één blok in de database.
final class Tracker: ObservableObject {
    static let shared = Tracker()

    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            UserDefaults.standard.set(Date(), forKey: "pausedAt")
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
        // Geldt voor alle Accessibility-vragen (ook het zoeken naar de chattitel): nooit langer dan 0,5 s wachten.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
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

    /// De eerste keer de vraag van macOS tonen (die zet TimeTrack meteen in de lijst); daarna rechtstreeks
    /// het juiste scherm in Systeeminstellingen openen, want macOS toont de vraag maar één keer.
    func requestAccessibility() {
        if !UserDefaults.standard.bool(forKey: "axPrompted") {
            UserDefaults.standard.set(true, forKey: "axPrompted")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            hasAccessibility = AXIsProcessTrustedWithOptions(options)
        } else {
            SystemSettings.open("Privacy_Accessibility")
        }
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
        if paused, let since = UserDefaults.standard.object(forKey: "pausedAt") as? Date,
           !Calendar.current.isDateInToday(since) {
            // Een vergeten pauze stopt de volgende dag vanzelf.
            paused = false
        }
        if paused { statusText = "Bijhouden gepauzeerd"; lastKey = nil; return }
        if sleeping || screenLocked { statusText = "Scherm vergrendeld"; lastKey = nil; return }
        guard let window = Self.activeWindow() else { statusText = "Geen actief venster"; lastKey = nil; return }

        let idle = Self.idleSeconds()
        // Een videocall of presentatie zonder muis/toetsenbord is geen inactiviteit (maximaal 2 uur).
        let isIdle = idle >= idleAfter && !(idle < 2 * 3600 && Self.callOrPresentationActive(frontmost: window.bundle))

        // Tijd in TimeTrack zelf (voorstellen nakijken) hoort bij het vorige blok.
        if window.bundle == Bundle.main.bundleIdentifier, lastKey != nil, !isIdle {
            Database.shared.run("UPDATE activity SET end=? WHERE id=?", now, lastId)
            return
        }

        let app = isIdle ? Store.idleApp : window.app
        let title = isIdle ? "" : window.title
        let host = isIdle ? "" : (Browser.host(bundleId: window.bundle) ?? "")
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
                // Ook blokken die tijdens de inactiviteit ontstonden (titelwissels) worden ingekort.
                start = now - idle
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
        let name = app.localizedName ?? "?"
        // Electron-apps (Claude, ChatGPT, Slack…) tonen vaak enkel hun naam als venstertitel;
        // de titel van het gesprek staat dan in de webinhoud van het venster.
        if (title.isEmpty || title == name), let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
           let web = webArea(window as! AXUIElement) {
            if let inner = web.title, inner != name, inner != "Claude", inner != "ChatGPT" {
                title = inner
            } else if let url = web.url, let chat = chatName(url) {
                // Chat-apps tonen geen gesprekstitel: een vaste naam per gesprek, zodat "Onthoud" werkt.
                title = chat
            }
        }
        return (name, app.bundleIdentifier ?? "", title)
    }

    /// "https://claude.ai/chat/4f2a91c3-…" → "Claude-chat 4f2a91c3"
    private static func chatName(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(where: { $0 == "chat" || $0 == "c" }), index + 1 < parts.count else { return nil }
        let id = String(parts[index + 1].prefix(8))
        let app = host.contains("claude") ? "Claude" : host.contains("openai") || host.contains("chatgpt") ? "ChatGPT" : host
        return "\(app)-chat \(id)"
    }

    /// Zoekt (beperkt in diepte en aantal) het eerste AXWebArea-element: titel en adres van de inhoud.
    private static func webArea(_ root: AXUIElement) -> (title: String?, url: URL?)? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 150 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" {
                var title: String?
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    var value: CFTypeRef?
                    if title == nil, AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                       let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        title = text
                    }
                }
                var urlValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlValue)
                let url = (urlValue as? URL) ?? (urlValue as? String).flatMap(URL.init(string:))
                return (title, url)
            }
            guard depth < 8 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.prefix(30).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Programma's waarvan een "scherm wakker houden" op een gesprek of presentatie wijst.
    private static let callApps = ["zoom.us", "Microsoft Teams", "MSTeams", "FaceTime", "Webex", "Slack", "Around",
                                   "Keynote", "Microsoft PowerPoint", "Loom", "Flow"]

    /// Paden van de programma's die nu het scherm wakker houden (één keer opvragen per ronde).
    static func displayAwakeHolders() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return dict.compactMap { pid, assertions in
            let keepsDisplayOn = assertions.contains {
                ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep"
                    || ($0["AssertionTrueType"] as? String) == "PreventUserIdleDisplaySleep"
            }
            return keepsDisplayOn ? processPath(pid.int32Value) : nil
        }
    }

    /// True tijdens een gesprek, presentatie of video: een call-app of Keynote/PowerPoint houdt het scherm wakker,
    /// of het programma vooraan doet dat (bv. een meeting of een uitlegvideo in de browser: ook dat is werk).
    /// Hulpjes als caffeinate of Amphetamine tellen niet; de tracker begrenst dit op 2 uur zonder invoer.
    static func callOrPresentationActive(frontmost bundleId: String) -> Bool {
        let holders = displayAwakeHolders()
        guard !holders.isEmpty else { return false }
        if holders.contains(where: { path in callApps.contains { path.contains("/\($0).app/") } }) { return true }
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path else { return false }
        return holders.contains { $0.hasPrefix(front) }
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Leest het domein van het actieve tabblad in gangbare browsers (macOS vraagt eenmalig toestemming per browser).
/// Het opvragen gebeurt op de achtergrond met een korte time-out, zodat een hangende browser TimeTrack niet
/// blokkeert; de tracker gebruikt het laatst gekende domein. Incognito-/privévensters van Chromium-browsers
/// worden overgeslagen.
enum Browser {
    private static let chromium = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                                   "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]
    private static let queue = DispatchQueue(label: "be.mtea.timetrack.browser")
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var running = false

    static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "browserDisabled") }

    enum Permission { case granted, denied, unknown }

    /// Gaf de gebruiker toestemming om de geopende browsers uit te lezen? (Enkel na te gaan voor browsers die draaien.)
    static func automationPermission() -> Permission {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter { $0 == "com.apple.Safari" || chromium.contains($0) }
        var result = Permission.unknown
        for bundleId in running {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
            if status == 0 { result = .granted }
            if status == OSStatus(errAEEventNotPermitted) { return .denied }
        }
        return result
    }

    /// Laatst gekend domein, zonder een nieuwe lezing te starten.
    static func cachedHost(bundleId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let known = cache[bundleId]
        return known?.isEmpty == false ? known : nil
    }

    /// Laatst gekend domein voor deze browser (bv. "janssen.be"), en start op de achtergrond een nieuwe lezing.
    static func host(bundleId: String) -> String? {
        guard isEnabled, let script = script(for: bundleId) else { return nil }
        lock.lock()
        let known = cache[bundleId]
        let busy = running
        if !busy { running = true }
        lock.unlock()
        if !busy {
            queue.async {
                let host = read(script)
                lock.lock()
                cache[bundleId] = host ?? ""
                running = false
                lock.unlock()
            }
        }
        return known?.isEmpty == false ? known : nil
    }

    private static func script(for bundleId: String) -> String? {
        if bundleId == "com.apple.Safari" {
            return "with timeout of 2 seconds\ntell application id \"com.apple.Safari\" to get URL of front document\nend timeout"
        }
        guard chromium.contains(bundleId) else { return nil }
        return """
            with timeout of 2 seconds
            tell application id "\(bundleId)"
                try
                    if mode of front window is "incognito" then return ""
                end try
                return URL of active tab of front window
            end tell
            end timeout
            """
    }

    private static func read(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        let url = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
