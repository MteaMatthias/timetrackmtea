import AppKit
import SwiftUI
import XCTest
@testable import TimeTrack

/// Rookt de echte SwiftUI-schermen in echte AppKit-vensters (GitHub macOS-runners hebben een window server):
/// opbouwen, inhoud wisselen, de run loop laten draaien en layouten. Een AppKit-uitzondering (zoals
/// "too many Update Constraints in Window passes") laat het testproces crashen en valt dus meteen op.
final class UISmokeTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27))!
    private let janssen = Company(id: "c-janssen", name: "Janssen NV", domains: ["janssen.be"])
    private let peeters = Company(id: "c-peeters", name: "Bakkerij Peeters BV", domains: ["bakkerijpeeters.be"])

    override func setUp() {
        super.setUp()
        let db = Database.shared
        for table in ["activity", "rules", "dismissed", "companies", "pushed", "calls", "call_memory", "assignments"] {
            db.run("DELETE FROM \(table)")
        }
        Store.replaceCompanies([janssen, peeters])
    }

    // MARK: - Hulpjes

    private func t(_ h: Int, _ m: Int = 0, _ s: Int = 0) -> Double {
        Calendar.current.date(bySettingHour: h, minute: m, second: s, of: day)!.timeIntervalSince1970
    }

    private func activity(_ from: Double, _ to: Double, app: String = "Google Chrome", title: String = "", host: String = "") {
        Database.shared.run("INSERT INTO activity(start, end, app, bundle, title, host) VALUES (?,?,?,?,?,?)",
                            from, to, app, "", title, host)
    }

    /// Een gewone dag: verspreid werk voor Janssen, Peeters, een chat, een gesprek, niet-herkend werk.
    private func busyDay() -> [CallRecord] {
        activity(t(8, 30), t(9, 15), host: "janssen.be")
        activity(t(9, 15), t(9, 40), app: "Microsoft Word", title: "Offerte Janssen.docx")
        activity(t(9, 40), t(10), app: "Claude", title: "Tekst herschrijven")
        activity(t(10), t(10, 6), app: "Flow", title: "Flow")
        activity(t(10, 6), t(11, 30), host: "bakkerijpeeters.be")
        activity(t(13), t(14), app: "Figma", title: "Ontwerp homepage")
        activity(t(14), t(14, 20), host: "janssen.be")
        var call = CallRecord(start: t(10, 0, 20), end: t(10, 5, 40), kind: .phone, label: "0493 29 50 63",
                              detail: "Piet · Janssen", memoryKey: "tel:493295063", companyId: "c-janssen",
                              companyName: "Janssen NV", confirmed: true)
        call.id = Store.save(call)
        return [call]
    }

    private func busyPlan(bundle: Bool = true) -> DayPlan {
        let calls = busyDay()
        let registered = [
            Registered(id: "r1", start: t(11), duration: 1800, companyId: "c-peeters", companyName: "Bakkerij Peeters BV",
                       description: "Bestelling"),
            Registered(id: "r2", start: nil, duration: 900, companyId: nil, companyName: "Intern", description: "", day: "2026-10-27"),
        ]
        return Planner.plan(day: day, registered: registered, matcher: Matcher(ownDomain: "mtea.be", excluded: [], ownNames: []),
                            roundTo: 5, events: [], bundle: bundle, calls: calls)
    }

    @MainActor private func requireWindowServer() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil, !NSScreen.screens.isEmpty else {
            throw XCTSkip("Geen window server of scherm beschikbaar")
        }
    }

    @MainActor private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    @MainActor private func environment<V: View>(_ view: V) -> AnyView {
        AnyView(view
            .environmentObject(Teamleader.shared)
            .environmentObject(AppModel.shared)
            .environmentObject(DayModel.shared)
            .environmentObject(Tracker.shared)
            .environmentObject(CalendarSource.shared)
            .environmentObject(CallWatcher.shared))
    }

    @MainActor private func settle(_ window: NSWindow) {
        pump(0.03)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        pump(0.03)
    }

    @MainActor private func makeWindow<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: environment(view))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        settle(window)
        return (window, hosting)
    }

    @MainActor private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
        pump(0.02)
    }

    @MainActor private func assertSane(_ hosting: NSView, maxHeight: CGFloat = 4000, _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let size = hosting.fittingSize
        XCTAssertTrue(size.width.isFinite && size.height.isFinite, "\(what): oneindige grootte", file: file, line: line)
        XCTAssertGreaterThan(size.height, 10, "\(what): niets getekend", file: file, line: line)
        XCTAssertLessThan(size.height, maxHeight, "\(what): onredelijk hoog (\(size.height))", file: file, line: line)
    }

    // MARK: - Vraag bij een gesprek (CallPrompt)

    @MainActor private func callPromptPanel() -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.identifier?.rawValue != "harness" && $0.isFloatingPanel && $0.level == .floating
                && $0.styleMask.contains(.nonactivatingPanel) && abs($0.frame.width - CallPrompt.size.width) < 1
        }
    }

    @MainActor func testCallPromptPanelHasAFixedSizeAndStaysOnScreen() throws {
        try requireWindowServer()
        let started = Date()
        CallPrompt.shared.show()
        pump(0.1)
        guard let panel = callPromptPanel() else { return XCTFail("geen vraagpaneel gevonden na CallPrompt.shared.show()") }
        XCTAssertTrue(panel.isVisible)
        let size = panel.frame.size
        XCTAssertEqual(panel.contentView?.frame.width ?? 0, CallPrompt.size.width, accuracy: 1)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame) },
                      "het paneel valt (deels) buiten het scherm: \(panel.frame) / \(NSScreen.main?.visibleFrame ?? .zero)")

        // Opnieuw tonen (volgend gesprek) en de inhoud laten wijzigen: zelfde paneel, zelfde grootte.
        for i in 0..<6 {
            CallPrompt.shared.show()
            CallWatcher.shared.addNumberToCompany = i % 2 == 0
            AppModel.shared.changed()
            pump(0.02)
            panel.layoutIfNeeded()
            panel.displayIfNeeded()
            XCTAssertEqual(panel.frame.size, size, "paneel veranderde van grootte")
        }
        XCTAssertEqual(NSApp.windows.filter { $0 === panel }.count, 1)
        XCTAssertEqual(NSApp.windows.compactMap { $0 as? NSPanel }.filter {
            $0.identifier?.rawValue != "harness" && $0.isFloatingPanel && $0.isVisible
        }.count, 1, "maar één vraagpaneel tegelijk")

        // Antwoorden zonder lopend gesprek mag niets doen (en zeker niet crashen).
        CallWatcher.shared.confirm()
        CallWatcher.shared.choose(Match(companyId: "c-janssen", companyName: "Janssen NV"))
        CallWatcher.shared.noClient()
        CallWatcher.shared.dismissPrompt()
        XCTAssertTrue(pump(until: { !panel.isVisible }, timeout: 1), "paneel verdwijnt na 'later beslissen'")
        XCTAssertNil(CallWatcher.shared.current)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// De crash van de eigenaar: bij het kiezen van een klant wisselde de inhoud van grootte en raakte AppKit in een
    /// eindeloze constraint-lus. CallWatcher.current kan niet van buitenaf gezet worden, dus deze test bouwt het
    /// paneel exact zoals CallPrompt.show() en speelt de inhoud van CallPromptView na met de echte CompanyField.
    @MainActor func testChoosingAClientInTheFixedCallPanelNeverResizesOrLoops() throws {
        try requireWindowServer()
        let state = PromptState()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: CallPrompt.size),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("harness")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: environment(PromptHarness(state: state)))
        hosting.frame = NSRect(origin: .zero, size: CallPrompt.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(CallPrompt.size)
        panel.contentMinSize = CallPrompt.size
        panel.contentMaxSize = CallPrompt.size
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - CallPrompt.size.width / 2, y: screen.visibleFrame.midY))
        }
        panel.orderFrontRegardless()
        defer { close(panel) }
        settle(panel)
        let size = panel.frame.size
        let started = Date()

        let names = ["Bakkerij Peeters BV", "", "Janssen NV",
                     "Een heel lange bedrijfsnaam die niet op één regel past omdat ze veel te lang is NV", internalLabel]
        for round in 0..<12 {
            // Gesprek start → "Is dit Janssen NV?" → "Andere klant" → klant gekozen → vinkje → opslaan → volgend gesprek.
            state.hasCall = true
            state.suggestion = round % 3 == 0 ? nil : "Janssen NV"
            state.detail = round % 2 == 0 ? "Piet · Janssen" : ""
            step(panel, size)
            state.choosing = true
            step(panel, size)
            state.companyName = names[round % names.count]
            state.companyId = state.companyName.isEmpty ? nil : "c-x"
            step(panel, size)
            state.numberUnknown.toggle()
            step(panel, size)
            state.companyName = ""
            step(panel, size)
            state.choosing = false
            state.hasCall = round % 4 != 3
            step(panel, size)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "inhoud wisselen in het paneel is traag (layout-lus?)")
    }

    @MainActor private func step(_ panel: NSPanel, _ size: NSSize, file: StaticString = #filePath, line: UInt = #line) {
        pump(0.01)
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
        XCTAssertEqual(panel.frame.size, size, "vast paneel veranderde van grootte", file: file, line: line)
        XCTAssertEqual(panel.contentView?.frame.size.width ?? 0, CallPrompt.size.width, accuracy: 1, file: file, line: line)
    }

    // MARK: - Voorstelkaarten

    @MainActor func testProposalCardsRenderForBundledCallAndUnassignedProposals() throws {
        try requireWindowServer()
        let plan = busyPlan()
        XCTAssertGreaterThanOrEqual(plan.proposals.count, 2, "testdag levert voorstellen op")
        var cards = plan.proposals
        // Uitersten: niet herkend met lange teksten, en een bundel met heel veel blokken.
        cards.append(Proposal(start: t(15), end: t(15, 20), match: .unassigned, reasons: [],
                              activities: [String(repeating: "Figma: Een heel lange venstertitel ", count: 6) + "· 20 min"],
                              description: "", learnPattern: "Figma", parts: [.init(start: t(15), end: t(15, 20))], seconds: 1200))
        let many = (0..<40).map { Proposal.Part(start: t(6) + Double($0) * 900, end: t(6) + Double($0) * 900 + 300) }
        cards.append(Proposal(start: many[0].start, end: many[many.count - 1].end,
                              match: Match(companyId: "c-janssen", companyName: "Janssen NV"),
                              reasons: ["website janssen.be · 3u20"], activities: [], description: "", learnPattern: "janssen.be",
                              parts: many, seconds: 12000, bundled: true,
                              pieces: many.map { Proposal.Piece(start: $0.start, end: $0.end, label: "Google Chrome: janssen.be") }))

        let (window, hosting) = makeWindow(ProposalCard(proposal: cards[0], model: DayModel.shared), size: NSSize(width: 1000, height: 320))
        defer { close(window) }
        let started = Date()
        for card in cards {
            hosting.rootView = environment(ProposalCard(proposal: card, model: DayModel.shared))
            settle(window)
            assertSane(hosting, maxHeight: 1200, "kaart \(card.match.companyName)")
        }
        for width in [520.0, 1400.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 320))
            settle(window)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    @MainActor func testBlockAssignPopoverHasAStableSizeWithAndWithoutPieces() throws {
        try requireWindowServer()
        let part = Proposal.Part(start: t(9), end: t(10))
        let onePiece = [Proposal.Piece(start: t(9), end: t(10), label: "Google Chrome: janssen.be")]
        let threePieces = [Proposal.Piece(start: t(8, 30), end: t(9, 20), label: "Google Chrome: janssen.be"),   // valt deels buiten
                           Proposal.Piece(start: t(9, 20), end: t(9, 40), label: "Microsoft Word: Offerte Janssen.docx"),
                           Proposal.Piece(start: t(9, 40), end: t(10), label: "Claude: Tekst herschrijven")]
        let manyPieces = (0..<30).map { Proposal.Piece(start: t(9) + Double($0) * 120, end: t(9) + Double($0 + 1) * 120,
                                                       label: "Stuk \($0) met een lange omschrijving van wat er gebeurde") }
        let (window, hosting) = makeWindow(BlockAssignView(part: part, current: "Janssen NV", pieces: onePiece) {},
                                           size: NSSize(width: 600, height: 500))
        defer { close(window) }
        XCTAssertEqual(hosting.fittingSize.width, 560, accuracy: 1)
        XCTAssertEqual(hosting.fittingSize.height, 260, accuracy: 1)
        let variants: [([Proposal.Piece], CGFloat)] = [(threePieces, 460), (manyPieces, 460), ([], 260)]
        for (pieces, height) in variants {
            hosting.rootView = environment(BlockAssignView(part: part, current: "", pieces: pieces) {})
            settle(window)
            XCTAssertEqual(hosting.fittingSize.width, 560, accuracy: 1)
            XCTAssertEqual(hosting.fittingSize.height, height, accuracy: 1, "\(pieces.count) delen")
        }
    }

    // MARK: - Tijdlijn

    @MainActor func testDayTimelineRendersAtAnyWidth() throws {
        try requireWindowServer()
        let plan = busyPlan()
        var odd = DayPlan()
        odd.activity = [TimelineBlock(id: 0, start: t(23, 30), end: t(23, 30) + 7200, label: "Janssen NV", kind: .assigned),
                        TimelineBlock(id: 1, start: t(5), end: t(5), label: "Niet toegewezen", kind: .unassigned)]
        odd.registered = [Registered(id: "x", start: t(7), duration: 0, companyId: nil, companyName: "", description: "")]
        let (window, hosting) = makeWindow(DayTimeline(plan: plan, day: day).frame(height: 150), size: NSSize(width: 1000, height: 170))
        defer { close(window) }
        let started = Date()
        for (p, d) in [(plan, day), (DayPlan(), day), (odd, day), (plan, Date())] {
            hosting.rootView = environment(DayTimeline(plan: p, day: d).frame(height: 150))
            for width in [1000.0, 300.0, 60.0, 2400.0] {
                window.setContentSize(NSSize(width: width, height: 170))
                settle(window)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    // MARK: - Hele schermen

    @MainActor func testTodayViewLoadsTheDayAndShowsItsProposals() throws {
        try requireWindowServer()
        _ = busyDay()
        DayModel.shared.day = day
        let expected = Planner.plan(day: day, registered: [], matcher: Matcher.current(), roundTo: Prefs.roundTo,
                                    bundle: Prefs.bundlePerClient).proposals.count
        XCTAssertGreaterThan(expected, 0)
        let (window, hosting) = makeWindow(TodayView(), size: NSSize(width: 1120, height: 780))
        defer { close(window) }
        XCTAssertTrue(pump(until: { DayModel.shared.plan.proposals.count == expected && !DayModel.shared.loading }, timeout: 3),
                      "Vandaag toont \(DayModel.shared.plan.proposals.count) voorstellen, verwacht \(expected)")
        settle(window)
        assertSane(hosting, maxHeight: 20000, "Vandaag")
        window.setContentSize(NSSize(width: 700, height: 500))
        settle(window)
    }

    /// Snel na elkaar herladen en van dag wisselen: het venster toont uiteindelijk de juiste dag, zonder te crashen.
    @MainActor func testRapidReloadsAndDaySwitchesEndOnTheRightDay() throws {
        try requireWindowServer()
        _ = busyDay()
        let other = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        DayModel.shared.day = other
        let (window, _) = makeWindow(TodayView(), size: NSSize(width: 1120, height: 780))
        defer { close(window) }
        for i in 0..<10 {
            DayModel.shared.day = i % 2 == 0 ? day : other
            AppModel.shared.changed()
            pump(0.01)
        }
        DayModel.shared.day = day
        AppModel.shared.changed()
        let expected = Planner.plan(day: day, registered: [], matcher: Matcher.current(), roundTo: Prefs.roundTo,
                                    bundle: Prefs.bundlePerClient).proposals.map(\.id)
        XCTAssertTrue(pump(until: { DayModel.shared.plan.proposals.map(\.id) == expected && !DayModel.shared.loading }, timeout: 3),
                      "na snel wisselen: \(DayModel.shared.plan.proposals.map(\.id)) in plaats van \(expected)")
    }

    @MainActor func testMenuBarPanelRendersAtItsFixedWidth() throws {
        try requireWindowServer()
        let (window, hosting) = makeWindow(MenuContent(open: {}), size: NSSize(width: 340, height: 420))
        defer { close(window) }
        pump(until: { !DayModel.menu.loading }, timeout: 2)
        settle(window)
        XCTAssertEqual(hosting.fittingSize.width, 340, accuracy: 1)
        assertSane(hosting, maxHeight: 900, "menubalk")
    }

    @MainActor func testWeekAndCorrectionScreensRender() throws {
        try requireWindowServer()
        _ = busyDay()
        let (window, hosting) = makeWindow(WeekView(tab: .constant(1)), size: NSSize(width: 1000, height: 700))
        defer { close(window) }
        pump(0.2)
        assertSane(hosting, "Week")
        Store.save(Rule(field: "any", pattern: "youtube.com", skip: true))
        Store.save(Rule(field: "title", pattern: "offerte janssen", companyId: "c-janssen", companyName: "Janssen NV"))
        hosting.rootView = environment(RulesView())
        settle(window)
        assertSane(hosting, "Correcties")
    }
}

// MARK: - Nabootsing van CallPromptView (zelfde opbouw, maar met instelbare toestand)

@MainActor
private final class PromptState: ObservableObject {
    @Published var hasCall = true
    @Published var detail = "Piet · Janssen"
    @Published var suggestion: String? = "Janssen NV"
    @Published var choosing = false
    @Published var companyId: String?
    @Published var companyName = ""
    @Published var numberUnknown = true
    @Published var addNumber = true
}

private struct PromptHarness: View {
    @ObservedObject var state: PromptState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.hasCall {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "phone.fill").font(.title3).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gesprek met 0493 29 50 63").font(.headline).lineLimit(1)
                        if !state.detail.isEmpty {
                            Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {} label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                if let suggestion = state.suggestion, !state.choosing {
                    Text("Is dit **\(suggestion)**?")
                    Text("eerder door jou gekozen").font(.caption).foregroundStyle(.secondary)
                    toggle(suggestion)
                    HStack {
                        Button("Ja") {}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        Button("Andere klant") { state.choosing = true }
                        Spacer()
                        Button("Geen klant") {}.buttonStyle(.link)
                    }
                } else {
                    Text(state.suggestion == nil ? "Voor welke klant is dit gesprek?" : "Kies de klant:")
                    CompanyField(id: $state.companyId, name: $state.companyName, compact: true)
                    if !state.companyName.isEmpty { toggle(state.companyName) }
                    HStack {
                        Button("Opslaan") {}.buttonStyle(.borderedProminent).disabled(state.companyName.isEmpty)
                        Spacer()
                        Button("Geen klant") {}.buttonStyle(.link)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: CallPrompt.size.width, height: CallPrompt.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func toggle(_ company: String) -> some View {
        if state.numberUnknown {
            Toggle(isOn: $state.addNumber) {
                Text("0493 29 50 63 toevoegen aan de fiche van \(company) in Teamleader").font(.callout)
            }
        }
    }
}
