import AppKit
import ApplicationServices
import SwiftUI

/// Wat de telefoonapp of een meeting op dit moment toont.
struct DetectedCall: Equatable {
    var kind: CallRecord.Kind
    var key: String              // vaste sleutel: "tel:493295063" of "meet:weekoverleg janssen"
    var label: String
    var detail = ""
    var ringing = false
    var number = ""
    var companyHint = ""
    var eventTitle: String?
}

/// Volgt oproepen in Flow (Telavox) en meetings (Teams, Zoom, Google Meet, Loom, FaceTime, Webex).
/// Bij een nieuw gesprek verschijnt rechtsboven een vraag: "Is dit klant X?". Het gesprek komt met de
/// gekozen klant in het dagvoorstel; het antwoord wordt onthouden voor dat nummer of die meeting.
@MainActor
final class CallWatcher: ObservableObject {
    static let shared = CallWatcher()

    /// Het gesprek waarover de vraag gaat (blijft na het einde nog even staan om te kunnen antwoorden).
    @Published private(set) var current: CallRecord?
    @Published private(set) var suggestion: Match?
    @Published private(set) var suggestionReason = ""
    /// Staat het nummer nog nergens in Teamleader (niet bij een bedrijf, niet bij een contact)?
    @Published private(set) var numberUnknownInTeamleader = false
    /// Het nummer toevoegen aan de fiche van de gekozen klant (vinkje in de vraag).
    @Published var addNumberToCompany = true

    private var timer: Timer?
    private var activeKey: String?
    private var lastSeen: Double = 0
    private var wasActive = false
    private var answered = false
    private var hideTask: Task<Void, Never>?

    var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "callPromptsDisabled") }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { _ in
            Task { @MainActor in await CallWatcher.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() async {
        guard isEnabled, !Tracker.shared.paused, Tracker.shared.hasAccessibility else { return }
        let now = Date().timeIntervalSince1970
        if let detected = FlowReader.currentCall() ?? MeetingDetector.current() {
            if detected.key != activeKey {
                finish()
                await begin(detected, now)
            } else {
                update(detected, now)
            }
        } else if activeKey != nil, now - lastSeen > (current?.kind == .phone ? 7 : 45) {
            finish()
        }
    }

    // MARK: Verloop van een gesprek

    private func begin(_ d: DetectedCall, _ now: Double) async {
        activeKey = d.key
        lastSeen = now
        wasActive = !d.ringing
        answered = false
        hideTask?.cancel()

        var record = CallRecord(start: now, end: now, kind: d.kind, label: d.label, detail: d.detail, memoryKey: d.key)
        let matcher = Matcher.current()
        var guess: (Match, String)?
        if let remembered = Store.callMemory(d.key) {
            if remembered.skip {
                // Eerder als privé of "geen klant" aangeduid: niet meer vragen.
                record.skip = true
                record.confirmed = true
                record.id = Store.save(record)
                current = nil
                CallPrompt.shared.hide()
                return
            }
            guess = (remembered, "eerder door jou gekozen")
        } else if d.kind == .phone {
            guess = matcher.match(phone: d.number, companyHint: d.companyHint)
        } else if let title = d.eventTitle {
            guess = matcher.match(event: CalendarEvent(start: now, end: now, title: title, attendeeEmails: MeetingDetector.attendees(now)))
        } else {
            let hit = matcher.match(app: "", title: d.label, host: "")
            if hit.0.isAssigned { guess = hit }
        }
        apply(guess, to: &record)
        numberUnknownInTeamleader = d.kind == .phone && !(Phone.key(d.number).map(Store.companyHasPhone) ?? true)
        addNumberToCompany = !UserDefaults.standard.bool(forKey: "addPhoneDisabled")
        record.id = Store.save(record)
        current = record
        CallPrompt.shared.show()

        // Nummer niet herkend: een contact met dit nummer zoeken in Teamleader.
        if guess == nil, d.kind == .phone, let found = await Teamleader.shared.companyForPhone(d.number),
           current?.id == record.id, !answered {
            var updated = record
            numberUnknownInTeamleader = false
            apply((found, "contact in Teamleader"), to: &updated)
            Store.save(updated)
            current = updated
        }
    }

    private func apply(_ guess: (Match, String)?, to record: inout CallRecord) {
        suggestion = guess?.0
        suggestionReason = guess?.1 ?? ""
        record.companyId = guess?.0.companyId
        record.companyName = guess?.0.companyName ?? ""
    }

    private func update(_ d: DetectedCall, _ now: Double) {
        lastSeen = now
        guard var record = current, record.memoryKey == d.key else { return }
        if !d.ringing && !wasActive {
            // Opgenomen: het gesprek begint nu, niet toen het begon te rinkelen.
            wasActive = true
            record.start = now
        }
        record.end = now
        Store.save(record)
        current = record
    }

    private func finish() {
        guard activeKey != nil else { return }
        activeKey = nil
        guard let record = current else { return }
        if !wasActive {
            // Gemiste of geweigerde oproep: geen werk.
            Store.deleteCall(id: record.id)
            current = nil
            CallPrompt.shared.hide()
            return
        }
        AppModel.shared.changed()
        if answered {
            CallPrompt.shared.hide()
        } else {
            // Nog even laten staan, zodat je na het gesprek kan antwoorden.
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if !Task.isCancelled, self.activeKey == nil { self.dismissPrompt() }
            }
        }
    }

    // MARK: Antwoorden

    func confirm() {
        guard let s = suggestion else { return }
        choose(s)
    }

    func choose(_ match: Match) {
        guard var record = current else { return }
        record.companyId = match.companyId
        record.companyName = match.companyName
        record.skip = false
        record.confirmed = true
        save(record, remember: match)
    }

    func noClient() {
        guard var record = current else { return }
        record.skip = true
        record.confirmed = true
        save(record, remember: Match(skip: true))
    }

    func dismissPrompt() {
        CallPrompt.shared.hide()
        if activeKey == nil { current = nil }
    }

    private func save(_ record: CallRecord, remember match: Match) {
        Store.save(record)
        Store.remember(record.memoryKey, match)
        if record.kind == .phone, numberUnknownInTeamleader, addNumberToCompany, !match.skip,
           let companyId = match.companyId {
            UserDefaults.standard.set(false, forKey: "addPhoneDisabled")
            let number = record.label, name = match.companyName
            Task {
                do {
                    let added = try await Teamleader.shared.addPhone(number, toCompany: companyId)
                    Reminder.shared.notify(title: added ? "Nummer toegevoegd" : "Nummer stond er al",
                                           body: "\(number) staat op de fiche van \(name) in Teamleader.")
                } catch {
                    Reminder.shared.notify(title: "Nummer niet toegevoegd",
                                           body: "\(number) kon niet aan \(name) toegevoegd worden: \(error.localizedDescription)")
                }
            }
            numberUnknownInTeamleader = false
        } else if record.kind == .phone, numberUnknownInTeamleader, !addNumberToCompany, !match.skip {
            // Bewust uitgevinkt: de volgende keer standaard uit.
            UserDefaults.standard.set(true, forKey: "addPhoneDisabled")
        }
        answered = true
        current = record
        suggestion = match.skip ? nil : match
        AppModel.shared.changed()
        CallPrompt.shared.hide()
        if activeKey == nil { current = nil }
    }
}

// MARK: - Flow (Telavox)

/// Leest het gesprekspaneel van de Flow-app via de Accessibility-API:
/// "Inkomende oproep" of een teller (00:22) met "Ophangen", daaronder naam, bedrijf en nummer.
enum FlowReader {
    static let ringingWords: Set<String> = ["Inkomende oproep", "Incoming call", "Inkommande samtal", "Appel entrant"]
    static let activeWords: Set<String> = ["Ophangen", "Hang up", "Lägg på", "Raccrocher"]
    static let panelEndWords: Set<String> = ["Ophangen", "Verwijderen", "Antwoorden", "Hang up", "Decline", "Answer",
                                             "Weigeren", "Raccrocher", "Répondre"]

    static func app() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName == "Flow" || ($0.bundleIdentifier ?? "").lowercased().contains("telavox")
        }
    }

    static func currentCall() -> DetectedCall? {
        guard let app = app() else { return nil }
        return parse(texts(of: app))
    }

    /// Alle zichtbare teksten van de vensters van een app, in volgorde (begrensd).
    static func texts(of app: NSRunningApplication, limit: Int = 2500) -> [String] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium-apps stellen hun inhoud pas beschikbaar als een hulpprogramma erom vraagt.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [] }
        var out: [String] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard visited < limit, depth < 45 else { return }
            visited += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success, let s = value as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, t.count < 200, out.last != t { out.append(t) }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                for kid in kids { walk(kid, depth + 1) }
            }
        }
        for window in list { walk(window, 0) }
        return out
    }

    static func isTimer(_ s: String) -> Bool {
        s.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private static func isInitials(_ s: String) -> Bool { s.count <= 3 && s.hasSuffix(".") }

    /// Haalt het gesprekspaneel uit de teksten. Nil als er geen oproep loopt of binnenkomt.
    static func parse(_ texts: [String]) -> DetectedCall? {
        let ringingIndex = texts.firstIndex { ringingWords.contains($0) }
        let activeIndex = texts.firstIndex { activeWords.contains($0) }
        guard ringingIndex != nil || activeIndex != nil else { return nil }
        let endIndex = texts.firstIndex { panelEndWords.contains($0) } ?? texts.count
        let startIndex: Int
        if let r = ringingIndex, r < endIndex {
            startIndex = r
        } else if let t = texts[..<endIndex].lastIndex(where: isTimer) {
            startIndex = t
        } else {
            startIndex = max(0, endIndex - 10)
        }
        guard startIndex < endIndex else { return nil }
        let panel = Array(texts[startIndex..<endIndex])
        guard let number = panel.first(where: { Phone.looksLikeNumber($0) && !isTimer($0) }) else { return nil }
        let before = panel.prefix { $0 != number }.dropFirst()
            .filter { !isTimer($0) && !isInitials($0) && !ringingWords.contains($0) }
        let name = before.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) } ?? ""
        let company = before.dropFirst().first ?? ""
        return DetectedCall(kind: .phone, key: "tel:" + (Phone.key(number) ?? Phone.digits(number)), label: number,
                            detail: [name, company].filter { !$0.isEmpty }.joined(separator: " · "),
                            ringing: ringingIndex != nil && activeIndex == nil, number: number, companyHint: company)
    }
}

// MARK: - Meetings

enum MeetingDetector {
    /// Programma's die tijdens een gesprek of opname het scherm wakker houden.
    private static let apps: [(name: String, label: String)] = [
        ("Microsoft Teams", "Teams-gesprek"), ("MSTeams", "Teams-gesprek"), ("zoom.us", "Zoom-meeting"),
        ("Webex", "Webex-meeting"), ("FaceTime", "FaceTime-gesprek"), ("Loom", "Loom-opname"),
    ]

    static func current() -> DetectedCall? {
        let now = Date().timeIntervalSince1970
        var label: String?
        if let front = Tracker.activeWindow(), Browser.host(bundleId: front.bundle) == "meet.google.com",
           front.title.range(of: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil
            || front.title.hasPrefix("Meet") && front.title.count > 12 {
            label = cleaned(front.title)
        } else if let app = apps.first(where: { Tracker.appKeepsDisplayAwake(named: $0.name) }) {
            label = app.label
        }
        guard let label else { return nil }
        // Loopt er nu een afspraak in de agenda, dan is die titel de beste omschrijving.
        let event = CalendarSource.shared.events(from: now - 60, to: now + 60).first { !$0.title.isEmpty }
        let title = event?.title ?? label
        return DetectedCall(kind: .meeting, key: "meet:" + Matcher.normalize(title), label: title,
                            detail: event != nil ? label : "", eventTitle: event?.title)
    }

    static func attendees(_ now: Double) -> [String] {
        CalendarSource.shared.events(from: now - 60, to: now + 60).first?.attendeeEmails ?? []
    }

    private static func cleaned(_ title: String) -> String {
        var t = title
        for suffix in [" - Google Chrome", " — Google Chrome", " - Safari", " - Microsoft Edge", " - Brave"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        if t.hasPrefix("Meet - ") || t.hasPrefix("Meet – ") { t = String(t.dropFirst(7)) }
        return t.isEmpty ? "Google Meet" : t
    }
}

// MARK: - Vraag rechtsboven

/// Paneel dat toetsenbordinvoer aanvaardt (om een klant te zoeken) zonder TimeTrack naar voren te halen.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CallPrompt {
    static let shared = CallPrompt()
    private var panel: KeyPanel?

    func show() {
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                p.standardWindowButton(button)?.isHidden = true
            }
            let controller = NSHostingController(rootView: CallPromptView()
                .environmentObject(CallWatcher.shared)
                .environmentObject(Teamleader.shared))
            controller.sizingOptions = [.preferredContentSize]
            p.contentViewController = controller
            panel = p
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 12))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct CallPromptView: View {
    @EnvironmentObject var watcher: CallWatcher
    @State private var choosing = false
    @State private var companyId: String?
    @State private var companyName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let call = watcher.current {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: call.kind == .phone ? "phone.fill" : "video.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.kind == .phone ? "Gesprek met \(call.label)" : call.label)
                            .font(.headline).lineLimit(1)
                        if !call.detail.isEmpty {
                            Text(call.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { watcher.dismissPrompt() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Later beslissen (het gesprek staat in je dagvoorstel)")
                }
                if let suggestion = watcher.suggestion, !choosing {
                    Text("Is dit **\(suggestion.companyName)**?")
                    if !watcher.suggestionReason.isEmpty {
                        Text(watcher.suggestionReason).font(.caption).foregroundStyle(.secondary)
                    }
                    addNumberToggle(suggestion.companyName, hasId: suggestion.companyId != nil)
                    HStack {
                        Button("Ja") { watcher.confirm() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        Button("Andere klant") { choosing = true }
                        Spacer()
                        Button("Geen klant") { watcher.noClient() }
                            .buttonStyle(.link)
                            .help("Privé of intern: niet registreren en voor dit nummer niet meer vragen")
                    }
                } else {
                    Text(watcher.suggestion == nil ? "Voor welke klant is dit gesprek?" : "Kies de klant:")
                    CompanyField(id: $companyId, name: $companyName, compact: true)
                    if !companyName.isEmpty {
                        addNumberToggle(companyName, hasId: companyId != nil)
                    }
                    HStack {
                        Button("Opslaan") {
                            watcher.choose(Match(companyId: companyId, companyName: companyName))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(companyName.isEmpty)
                        Spacer()
                        Button("Geen klant") { watcher.noClient() }
                            .buttonStyle(.link)
                            .help("Privé of intern: niet registreren en voor dit nummer niet meer vragen")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .onChange(of: watcher.current?.memoryKey) { _ in
            choosing = false
            companyId = nil
            companyName = ""
        }
    }

    @ViewBuilder
    private func addNumberToggle(_ company: String, hasId: Bool) -> some View {
        if watcher.numberUnknownInTeamleader, hasId, let call = watcher.current {
            Toggle(isOn: $watcher.addNumberToCompany) {
                Text("\(call.label) toevoegen aan de fiche van \(company) in Teamleader").font(.callout)
            }
        }
    }
}
