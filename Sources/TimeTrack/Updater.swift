import AppKit
import Foundation
import Security
import UserNotifications

/// Controleert GitHub Releases op een nieuwere versie en installeert ze in place.
/// Een download via URLSession krijgt geen quarantaine-vlag, dus Gatekeeper komt niet tussen.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/MteaMatthias/timetrackmtea/releases/latest")!

    @Published private(set) var latest: String?
    @Published private(set) var installing = false
    @Published private(set) var error: String?
    private var downloadURL: URL?

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var updateAvailable: Bool { latest.map { Self.isNewer($0, than: current) } ?? false }

    func startPeriodicChecks() {
        Task {
            while true {
                await check()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func check() async {
        var req = URLRequest(url: Self.latestReleaseAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let response = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String) == "TimeTrack.zip" }
        latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        downloadURL = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
        error = nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func install() async {
        guard let downloadURL else { error = "Geen download gevonden."; return }
        installing = true
        error = nil
        do {
            let (file, _) = try await URLSession.shared.download(from: downloadURL)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timetrack-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", file.path, dir.path])
            let newApp = dir.appendingPathComponent("TimeTrack.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                throw NSError(domain: "TimeTrack", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download onvolledig."])
            }
            let dest = Bundle.main.bundlePath
            guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
                throw NSError(domain: "TimeTrack", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Geen schrijfrechten in \((dest as NSString).deletingLastPathComponent). Installeer opnieuw via tools.mtea.be."])
            }
            // Enkel een versie die met hetzelfde certificaat ondertekend is (niet zomaar een download).
            guard Self.signedLikeThisApp(newApp) else {
                throw NSError(domain: "TimeTrack", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "De handtekening van de nieuwe versie klopt niet. Installeer opnieuw via tools.mtea.be."])
            }
            // Na het afsluiten: eerst de nieuwe ernaast zetten, dan omwisselen. Mislukt iets, dan blijft de oude staan.
            let staged = dest + ".nieuw"
            let old = dest + ".oud"
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                rm -rf "\(staged)" "\(old)"
                ditto "\(newApp.path)" "\(staged)" || exit 1
                mv "\(dest)" "\(old)" && mv "\(staged)" "\(dest)" || { [ -d "\(old)" ] && [ ! -d "\(dest)" ] && mv "\(old)" "\(dest)"; }
                rm -rf "\(old)"
                xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
                open "\(dest)"
                """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            self.error = "Bijwerken mislukt: \(error.localizedDescription)"
            installing = false
        }
    }

    /// Voldoet de nieuwe app aan de vereiste van deze app (zelfde certificaat en identifier)?
    /// Is deze app nog zonder vast certificaat ondertekend (ad hoc), dan kan dat niet gecontroleerd worden.
    static func signedLikeThisApp(_ url: URL) -> Bool {
        var me: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess, let requirement else { return true }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        if (text as String?)?.contains("cdhash") ?? true { return true }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &newCode) == errSecSuccess, let newCode else { return false }
        return SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "TimeTrack", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) mislukt"])
        }
    }
}

/// Stuurt op werkdagen rond 17 u een melding als er nog tijd te registreren is.
final class Reminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminder()
    private var timer: Timer?

    private var enabled: Bool { UserDefaults.standard.object(forKey: "reminderEnabled") as? Bool ?? true }
    private var minuteOfDay: Int {
        let v = UserDefaults.standard.integer(forKey: "reminderMinute")
        return v > 0 ? v : 17 * 60
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Korte melding (bv. resultaat van het toevoegen van een nummer).
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func check() {
        let now = Date()
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let today = Store.dayKey(now)
        guard enabled, (2...6).contains(weekday), minute >= minuteOfDay,
              UserDefaults.standard.string(forKey: "reminderLastDay") != today else { return }
        UserDefaults.standard.set(today, forKey: "reminderLastDay")
        Task { @MainActor in
            let (lo, hi) = Store.dayBounds(now)
            guard Teamleader.shared.isConnected,
                  let registered = try? await Teamleader.shared.registered(from: lo, to: hi) else { return }
            let matcher = Matcher.current()
            let plan = Planner.plan(day: now, registered: registered, matcher: matcher, roundTo: Prefs.roundTo,
                                    bundle: Prefs.bundlePerClient)
            guard plan.proposedSeconds >= 15 * 60 else { return }
            let clients = Set(plan.proposals.filter { $0.match.isAssigned }.map { $0.match.companyName })
            let content = UNMutableNotificationContent()
            content.title = "Je dag staat klaar"
            content.body = "\(formatDuration(plan.proposedSeconds)) nog te registreren"
                + (clients.isEmpty ? "." : " voor \(clients.sorted().prefix(3).joined(separator: ", ")).")
                + " Klik om te bevestigen."
            let request = UNNotificationRequest(identifier: "daily-\(today)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if !Calendar.current.isDateInToday(DayModel.shared.day) { DayModel.shared.day = Date() }
            AppDelegate.shared?.showMainWindow()
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
