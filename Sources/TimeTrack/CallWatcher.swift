import AppKit
import ApplicationServices
import SwiftUI

/// Wat de telefoonapp of een meeting op dit moment toont.
struct DetectedCall: Equatable {
    var kind: CallRecord.Kind
    var key: String              // identiteit van dit gesprek: "tel:493295063", "meet:weekoverleg janssen"
    var memoryKey: String        // waaronder het antwoord onthouden wordt ("" = niet onthouden)
    var label: String
    var detail = ""
    var ringing = false
    var number = ""
    var companyHint = ""
    var eventTitle: String?
}

/// Volgt oproepen in Flow (Telavox) en meetings (Teams, Zoom, Google Meet, Loom, FaceTime, Webex).
/// Zodra een gesprek loopt (niet tijdens het rinkelen) verschijnt rechtsboven "Is dit klant X?". Voor een
/// nummer dat je al eens bevestigde, wordt niets meer gevraagd. Het gesprek komt met de klant in het dagvoorstel.
/// Het uitlezen gebeurt op de achtergrond, zodat TimeTrack nooit hapert.
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

    private var activeKey: String?
    private var lastSeen: Double = 0
    private var wasActive = false
    private var answered = false
    private var prompted = false
    private var pendingDetection: DetectedCall?
    private var hideTask: Task<Void, Never>?
    private var loop: Task<Void, Never>?

    var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "callPromptsDisabled") }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                await self.tick()
                // Tijdens een gesprek vaker kijken; anders rustig aan (spaart batterij en Flow).
                let seconds: UInt64 = self.activeKey != nil ? 2 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func tick() async {
        guard isEnabled, !Tracker.shared.paused, Tracker.shared.hasAccessibility else { return }
        let detected = await Task.detached(priority: .utility) {
            FlowReader.currentCall() ?? MeetingDetector.current()
        }.value
        let now = Date().timeIntervalSince1970
        if let detected {
            if detected.key != activeKey {
                finish()
                begin(detected, now)
            } else {
                await update(detected, now)
            }
        } else if activeKey != nil, now - lastSeen > (current?.kind == .phone ? 8 : 300) {
            // Een meeting in een ander venster loopt gewoon door; pas na 5 minuten zonder spoor is ze voorbij.
            finish()
        }
    }

    // MARK: Verloop van een gesprek

    private func begin(_ d: DetectedCall, _ now: Double) {
        activeKey = d.key
        lastSeen = now
        wasActive = !d.ringing
        answered = false
        prompted = false
        hideTask?.cancel()

        var record = CallRecord(start: now, end: now, kind: d.kind, label: d.label, detail: d.detail,
                                memoryKey: d.memoryKey)
        let remembered = Store.callMemory(d.memoryKey)
        if let remembered {
            // Al eens beantwoord: niets meer vragen.
            record.companyId = remembered.companyId
            record.companyName = remembered.companyName
            record.skip = remembered.skip
            record.confirmed = true
            answered = true
            suggestion = remembered.skip ? nil : remembered
            suggestionReason = "eerder door jou gekozen"
        } else {
            let matcher = Matcher.current()
            var guess: (Match, String)?
            if d.kind == .phone {
                guess = matcher.match(phone: d.number, companyHint: d.companyHint)
            } else if let title = d.eventTitle {
                guess = matcher.match(event: CalendarEvent(start: now, end: now, title: title,
                                                           attendeeEmails: MeetingDetector.attendees(now)))
            } else {
                let hit = matcher.match(app: "", title: d.label, host: "")
                if hit.0.isAssigned { guess = hit }
            }
            apply(guess, to: &record)
        }
        numberUnknownInTeamleader = d.kind == .phone && !(Phone.key(d.number).map(Store.companyHasPhone) ?? true)
        addNumberToCompany = !UserDefaults.standard.bool(forKey: "addPhoneDisabled")
        record.id = Store.save(record)
        current = record
        pendingDetection = d
        if wasActive { Task { await self.promptIfNeeded() } }
    }

    /// Vraag tonen zodra het gesprek loopt (en enkel als het antwoord nog niet gekend is).
    private func promptIfNeeded() async {
        guard !prompted, !answered, let d = pendingDetection, let record = current else { return }
        prompted = true
        CallPrompt.shared.show()
        // Nummer niet herkend: pas nu (opgenomen) een contact met dit nummer zoeken in Teamleader.
        if suggestion == nil, d.kind == .phone, let found = await Teamleader.shared.companyForPhone(d.number),
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

    private func update(_ d: DetectedCall, _ now: Double) async {
        lastSeen = now
        guard var record = current, activeKey == d.key else { return }
        if !d.ringing && !wasActive {
            // Opgenomen: het gesprek begint nu, niet toen het begon te rinkelen.
            wasActive = true
            record.start = now
        }
        record.end = now
        Store.save(record)
        current = record
        if wasActive { await promptIfNeeded() }
    }

    private func finish() {
        guard activeKey != nil else { return }
        activeKey = nil
        pendingDetection = nil
        guard let record = current else { return }
        if !wasActive {
            // Gemiste of geweigerde oproep: geen werk.
            Store.deleteCall(id: record.id)
            current = nil
            CallPrompt.shared.hide()
            return
        }
        AppModel.shared.changed()
        if answered || !prompted {
            CallPrompt.shared.hide()
            current = nil
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
        // Enkel onthouden voor een nummer of een meeting met een eigen titel (niet voor "Teams-gesprek").
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
/// "Inkomende oproep" met de knoppen Verwijderen/Antwoorden (rinkelt), of een teller (00:22) met
/// Ophangen (loopt); daartussen naam, bedrijf en nummer.
enum FlowReader {
    static let ringingWords: Set<String> = ["Inkomende oproep", "Incoming call", "Inkommande samtal", "Appel entrant"]
    static let answerButtons: Set<String> = ["Antwoorden", "Answer", "Svara", "Répondre"]
    static let hangUpButtons: Set<String> = ["Ophangen", "Hang up", "Lägg på", "Raccrocher"]
    private static var enabledPids = Set<pid_t>()
    private static let lock = NSLock()

    static func app() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName == "Flow" || ($0.bundleIdentifier ?? "").lowercased().contains("telavox")
        }
    }

    static func currentCall() -> DetectedCall? {
        guard let app = app() else { return nil }
        return parse(texts(of: app))
    }

    /// Alle zichtbare teksten van de vensters van een app, in volgorde; begrensd in aantal en tijd.
    static func texts(of app: NSRunningApplication, limit: Int = 3000, budget: TimeInterval = 0.4) -> [String] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        lock.lock()
        let first = enabledPids.insert(app.processIdentifier).inserted
        lock.unlock()
        if first {
            // Electron/Chromium-apps stellen hun inhoud pas beschikbaar als een hulpprogramma erom vraagt.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var out: [String] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard visited < limit, depth < 45, visited % 50 != 0 || Date() < deadline else { return }
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
    /// Het paneel wordt herkend aan de knoppen (Antwoorden of Ophangen), niet aan losse woorden elders.
    static func parse(_ texts: [String]) -> DetectedCall? {
        let answerIndex = texts.firstIndex { answerButtons.contains($0) }
        let hangUpIndex = texts.firstIndex { hangUpButtons.contains($0) }
        let buttonIndex: Int
        let ringing: Bool
        let startIndex: Int
        if let h = hangUpIndex, let t = texts[..<h].lastIndex(where: isTimer) {
            buttonIndex = h
            ringing = false
            startIndex = t
        } else if let a = answerIndex, let r = texts[..<a].lastIndex(where: { ringingWords.contains($0) }) {
            buttonIndex = a
            ringing = true
            startIndex = r
        } else {
            return nil
        }
        guard startIndex < buttonIndex, buttonIndex - startIndex <= 15 else { return nil }
        let panel = Array(texts[startIndex..<buttonIndex])
        guard let number = panel.first(where: { Phone.looksLikeNumber($0) && !isTimer($0) }) else { return nil }
        let before = panel.prefix { $0 != number }.dropFirst()
            .filter { !isTimer($0) && !isInitials($0) && !ringingWords.contains($0) && !answerButtons.contains($0) }
        let name = before.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) } ?? ""
        let company = before.dropFirst().first ?? ""
        let key = "tel:" + (Phone.key(number) ?? Phone.digits(number))
        return DetectedCall(kind: .phone, key: key, memoryKey: key, label: number,
                            detail: [name, company].filter { !$0.isEmpty }.joined(separator: " · "),
                            ringing: ringing, number: number, companyHint: company)
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
        if let front = Tracker.activeWindow(), Browser.cachedHost(bundleId: front.bundle) == "meet.google.com",
           front.title.range(of: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil
            || front.title.hasPrefix("Meet") && front.title.count > 12 {
            label = cleaned(front.title)
        } else {
            let holders = Tracker.displayAwakeHolders()
            label = apps.first { app in holders.contains { $0.contains("/\(app.name)") } }?.label
        }
        guard let label else { return nil }
        // Loopt er nu een afspraak in de agenda, dan is die titel de beste omschrijving en kan het antwoord
        // onthouden worden. Een los "Teams-gesprek" niet: dat zegt niets over de klant.
        let event = CalendarSource.shared.events(from: now - 60, to: now + 60).first { !$0.title.isEmpty }
        let title = event?.title ?? label
        let key = "meet:" + Matcher.normalize(title)
        return DetectedCall(kind: .meeting, key: key, memoryKey: event != nil ? key : "", label: title,
                            detail: event != nil ? label : "", eventTitle: event?.title)
    }

    static func attendees(_ now: Double) -> [String] {
        CalendarSource.shared.events(from: now - 60, to: now + 60).first?.attendeeEmails ?? []
    }

    private static func cleaned(_ title: String) -> String {
        var t = Matcher.cleanTitle(title)
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
