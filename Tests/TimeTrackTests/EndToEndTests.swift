import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import TimeTrack

/// End-to-end: de ECHTE CallWatcher leest via de Accessibility-API een nep-"Flow"-app (E2E/FakeFlow, gebouwd
/// door E2E/build-fakeflow.sh) die rinkelt, opneemt en ophangt. De echte vraag rechtsboven (CallPrompt) wordt
/// zoals een gebruiker bediend, de echte Store/Planner/DayModel maken het voorstel, en de echte Teamleader-klasse
/// registreert bij een nep-Teamleader (URLProtocol in dit proces). Zie E2E/README.md.
///
/// Draait enkel met TIMETRACK_E2E=1 en TIMETRACK_DATA_DIR (CI); anders overgeslagen, met de reden erbij.
/// Elke overgeslagen test drukt een regel "E2E-SKIP: …" af; de diagnose drukt "E2E-DIAG: …" af.
final class EndToEndTests: XCTestCase {
    static let number = "0493 29 50 63"
    static let memoryKey = "tel:493295063"
    static let mm = Match(companyId: "c-mm", companyName: "M&M")

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { env["TIMETRACK_E2E"] == "1" }
    static var hasDataDir: Bool { !(env["TIMETRACK_DATA_DIR"] ?? "").isEmpty }
    /// Hoe lang een opgenomen gesprek duurt (echte seconden). 70 s: over een minuutgrens, dus 2 min verwacht
    /// (afronden op 5/10/15 min of op minuutgrenzen valt meteen op).
    static var callSeconds: Double { Double(env["TIMETRACK_E2E_CALL_SECONDS"] ?? "") ?? 70 }

    private static var fakeFlow: E2EFakeFlow?
    private static var seededKeychain = false
    private static var connectedByUs = false
    private static var appDelegate: AppDelegate?

    // MARK: - Klasse opzetten en opruimen

    override class func setUp() {
        super.setUp()
        guard enabled, hasDataDir else { return }
        NSSetUncaughtExceptionHandler { exception in
            print("E2E: ONOPGEVANGEN NSException \(exception.name.rawValue): \(exception.reason ?? "")")
            print(exception.callStackSymbols.prefix(30).joined(separator: "\n"))
        }
        // Uitzonderingen die AppKit anders enkel logt, laten het proces crashen (zoals in de echte app zou moeten opvallen).
        UserDefaults.standard.set(true, forKey: "NSApplicationCrashOnExceptions")
        URLProtocol.registerClass(E2EFakeTeamleader.self)
        // Weg 1 naar een verbonden Teamleader.shared: tokens klaarzetten in de sleutelhanger vóór Teamleader.shared
        // voor het eerst gebruikt wordt (storedTokens is lazy). Werkt niet als een andere testklasse het al aanmaakte;
        // dan volgt weg 2 (verbinden via het nep-portaal, zie ensureTeamleader).
        if Keychain.data("tokens") == nil {
            struct SeedTokens: Codable { var access: String; var refresh: String; var expires: Date }
            let data = try? JSONEncoder().encode(SeedTokens(access: "e2e-access", refresh: "e2e-refresh",
                                                            expires: Date().addingTimeInterval(3000)))
            Keychain.set("tokens", data)
            seededKeychain = Keychain.data("tokens") != nil
            print("E2E-DIAG: tokens in de sleutelhanger gezet: \(seededKeychain)")
        }
    }

    override class func tearDown() {
        if enabled, hasDataDir {
            fakeFlow?.quit()
            fakeFlow = nil
            let seeded = seededKeychain, connected = connectedByUs
            Task { @MainActor in
                if seeded || connected { Teamleader.shared.disconnect() }
                for key in ["portalURL", "roundTo", "bundlePerClient", "addPhoneDisabled"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                CallPrompt.shared.hide()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            URLProtocol.unregisterClass(E2EFakeTeamleader.self)
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard Self.enabled, Self.hasDataDir else { return }
        for table in ["activity", "dismissed", "pushed", "calls", "call_memory", "assignments"] {
            Database.shared.run("DELETE FROM \(table)")
        }
        E2EFakeTeamleader.reset()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "callPromptsDisabled")
        // Het nummer staat al bij M&M; zo komt de melding na "nummer toevoegen" (UNUserNotificationCenter crasht
        // buiten een app-bundel) nooit aan bod.
        defaults.set(true, forKey: "addPhoneDisabled")
        defaults.set(Int(Self.env["TIMETRACK_E2E_ROUND_TO"] ?? "") ?? 15, forKey: "roundTo")
        defaults.set(true, forKey: "bundlePerClient")
        defaults.set(true, forKey: "onboarded")
        if Tracker.shared.paused { Tracker.shared.paused = false }
    }

    // MARK: - 0. Diagnose (faalt nooit; vertelt wat de runner toelaat)

    @MainActor func test0_Diagnostics() async throws {
        func diag(_ s: String) { print("E2E-DIAG: \(s)") }
        diag("TIMETRACK_E2E=\(Self.env["TIMETRACK_E2E"] ?? "-") TIMETRACK_DATA_DIR=\(Self.env["TIMETRACK_DATA_DIR"] ?? "-")")
        _ = NSApplication.shared
        diag("schermen: \(NSScreen.screens.count), NSScreen.main: \(NSScreen.main.map { "\($0.frame)" } ?? "geen")")
        diag("AXIsProcessTrusted() = \(AXIsProcessTrusted())  (Tracker.shared.hasAccessibility = \(Tracker.shared.hasAccessibility))")
        diag("proces: \(ProcessInfo.processInfo.processName) pid \(getpid()), pad \(CommandLine.arguments.first ?? "?")")
        diag("ouderketen (TCC kent toestemming toe aan het 'verantwoordelijke' proces):\n" + Self.processChain())
        diag("SIP: \(Self.shell("/usr/bin/csrutil", ["status"]))")
        diag("Teamleader.shared.isConnected = \(Teamleader.shared.isConnected), tokens zelf gezet = \(Self.seededKeychain)")
        guard Self.enabled else {
            diag("TIMETRACK_E2E staat niet op 1: de E2E-tests worden overgeslagen.")
            return
        }
        guard let appURL = E2EFakeFlow.locateApp() else {
            diag("Flow.app (nep) niet gevonden: \(E2EFakeFlow.defaultAppURL.path). Draai ./E2E/build-fakeflow.sh vóór swift test.")
            return
        }
        diag("nep-Flow: \(appURL.path)")
        do {
            let flow = try await ensureFakeFlow()
            diag("FlowReader.app() = \(FlowReader.app().map { "\($0.localizedName ?? "?") pid \($0.processIdentifier) \($0.bundleIdentifier ?? "")" } ?? "niet gevonden")")
            for state in ["idle", "ringing", "active"] {
                flow.set(state)
                try await Task.sleep(nanoseconds: 1_200_000_000)
                let texts = await Self.readFlowTexts()
                let call = FlowReader.parse(texts)
                diag("[\(state)] \(texts.count) teksten: \(texts.prefix(30).joined(separator: " | "))")
                diag("[\(state)] FlowReader.parse → \(call.map { "\($0.key) ringing=\($0.ringing) label=\($0.label) detail=\($0.detail)" } ?? "nil")")
            }
            flow.set("idle")
        } catch {
            diag("nep-Flow starten/lezen mislukt: \(error)")
        }
        do {
            try await ensureTeamleader()
            diag("Teamleader verbonden met de nep-Teamleader: \(Teamleader.shared.userName ?? "?"), \(Store.companies().count) bedrijven")
        } catch {
            diag("Teamleader niet verbonden: \(error)")
        }
    }

    // MARK: - a. Opgenomen gesprek: vraag pas na opnemen, klant kiezen, echte begintijd en duur, registreren

    @MainActor func test1_AnsweredCallIsPromptedAndBookedWithItsRealStartAndDuration() async throws {
        let flow = try await requireFlowE2E()
        let run = await simulateCall(flow, talk: Self.callSeconds, answer: { [self] in
            await self.chooseInPrompt(companySearch: "M&M", companyName: "M&M")
        })
        XCTAssertFalse(run.promptWhileRinging, "de vraag verscheen al tijdens het rinkelen (mag pas na opnemen)")
        XCTAssertTrue(run.promptAfterAnswer, "geen vraag verschenen na het opnemen")
        XCTAssertTrue(run.promptHiddenAfterChoice, "de vraag bleef staan na het kiezen van de klant")
        XCTAssertTrue(run.finished, "CallWatcher sloot het gesprek niet af na het ophangen")
        print("E2E: klant gekozen via \(run.choseViaUI ? "de echte knoppen in de vraag" : "CallWatcher.choose (UI niet bedienbaar)")")

        let records = callRecords()
        XCTAssertEqual(records.count, 1, "verwacht precies één gesprek in de database: \(records)")
        let record = try XCTUnwrap(records.first)
        let answerAt = try XCTUnwrap(run.answerAt)
        assertRecord(record, answeredAt: answerAt, hungUpAt: run.hangAt)

        let plan = await reloadPlan()
        let calls = plan.proposals.filter(\.isCall)
        XCTAssertEqual(calls.count, 1, "verwacht één gespreksvoorstel: \(describe(plan.proposals))")
        let proposal = try XCTUnwrap(calls.first)
        assertProposal(proposal, for: record)
        XCTAssertTrue(DayModel.shared.canRegister, "kan niet registreren: \(DayModel.shared.error ?? "-")")

        let error = await DayModel.shared.register(DayModel.shared.proposalToRegister(proposal))
        XCTAssertNil(error, "registreren mislukt: \(error ?? "")")
        let adds = E2EFakeTeamleader.adds
        XCTAssertEqual(adds.count, 1, "verwacht één timeTracking.add: \(adds)")
        if let add = adds.first { assertAdd(add, for: record) }

        let after = DayModel.shared.plan
        XCTAssertFalse(after.proposals.contains { $0.isCall && abs($0.start - record.start) < 1 },
                       "het geregistreerde gesprek wordt nog steeds voorgesteld: \(describe(after.proposals))")
        XCTAssertTrue(after.registered.contains { $0.companyId == "c-mm" }, "registratie niet terug gelezen uit Teamleader")
    }

    // MARK: - b. Zelfde nummer belt 1 minuut later opnieuw: opnieuw vragen, apart voorstellen en boeken

    @MainActor func test2_SameNumberCallingAgainAMinuteLaterIsAskedAndBookedSeparately() async throws {
        let flow = try await requireFlowE2E()
        let first = await simulateCall(flow, talk: 25, answer: { [self] in
            await self.chooseInPrompt(companySearch: "M&M", companyName: "M&M")
        })
        XCTAssertTrue(first.promptAfterAnswer, "1e gesprek: geen vraag")
        XCTAssertTrue(first.finished, "1e gesprek niet afgesloten")
        XCTAssertNotNil(Store.callMemory(Self.memoryKey), "keuze niet onthouden voor dit nummer")

        // Eén minuut na het ophangen belt hetzelfde nummer opnieuw (CallWatcher blijft intussen kijken).
        _ = await runWatcher(for: max(0, first.hangAt + 60 - now()))

        var suggestionDuringSecond: Match?
        var reasonDuringSecond = ""
        let second = await simulateCall(flow, talk: Self.callSeconds, onRinging: {
            suggestionDuringSecond = CallWatcher.shared.suggestion
            reasonDuringSecond = CallWatcher.shared.suggestionReason
        }, answer: { [self] in
            // De onthouden klant wordt voorgesteld: "Ja".
            if await self.pressInPrompt("Ja") { return true }
            CallWatcher.shared.confirm()
            return false
        })
        XCTAssertTrue(second.promptAfterAnswer, "2e gesprek van hetzelfde nummer: geen vraag (elke oproep moet gevraagd worden)")
        XCTAssertFalse(second.promptWhileRinging, "2e gesprek: vraag al tijdens het rinkelen")
        XCTAssertEqual(suggestionDuringSecond?.companyId, "c-mm", "2e gesprek: onthouden klant niet voorgesteld")
        XCTAssertEqual(reasonDuringSecond, "eerder door jou gekozen")
        XCTAssertTrue(second.finished, "2e gesprek niet afgesloten")

        let records = callRecords()
        XCTAssertEqual(records.count, 2, "verwacht twee aparte gesprekken: \(records)")
        guard records.count == 2 else { return }
        let (r1, r2) = (records[0], records[1])
        assertRecord(r1, answeredAt: try XCTUnwrap(first.answerAt), hungUpAt: first.hangAt)
        assertRecord(r2, answeredAt: try XCTUnwrap(second.answerAt), hungUpAt: second.hangAt)
        XCTAssertGreaterThan(r2.start, r1.end + 50, "het 2e gesprek overlapt of plakt aan het 1e")
        XCTAssertNotEqual(r1.id, r2.id)

        let plan = await reloadPlan()
        let calls = plan.proposals.filter(\.isCall).sorted { $0.start < $1.start }
        XCTAssertEqual(calls.count, 2, "verwacht twee aparte gespreksvoorstellen: \(describe(plan.proposals))")
        guard calls.count == 2 else { return }
        assertProposal(calls[0], for: r1)
        assertProposal(calls[1], for: r2)
        XCTAssertLessThanOrEqual(calls[0].end, calls[1].start, "voorstellen overlappen")

        // Elk apart registreren, zoals de gebruiker op de kaart klikt.
        let e1 = await DayModel.shared.register(DayModel.shared.proposalToRegister(calls[0]))
        XCTAssertNil(e1, "1e registratie mislukt: \(e1 ?? "")")
        let remaining = DayModel.shared.plan.proposals.filter(\.isCall)
        XCTAssertEqual(remaining.count, 1, "na het 1e registreren moet het 2e gesprek nog voorgesteld worden: \(describe(DayModel.shared.plan.proposals))")
        let next = try XCTUnwrap(remaining.first)
        assertProposal(next, for: r2)
        let e2 = await DayModel.shared.register(DayModel.shared.proposalToRegister(next))
        XCTAssertNil(e2, "2e registratie mislukt: \(e2 ?? "")")

        let adds = E2EFakeTeamleader.adds
        XCTAssertEqual(adds.count, 2, "verwacht twee timeTracking.add: \(adds)")
        if adds.count == 2 {
            assertAdd(adds[0], for: r1)
            assertAdd(adds[1], for: r2)
        }
        XCTAssertTrue(DayModel.shared.plan.proposals.filter(\.isCall).isEmpty,
                      "na beide registraties nog gespreksvoorstellen: \(describe(DayModel.shared.plan.proposals))")
    }

    // MARK: - c. Gemiste oproep: niets bewaard, niets voorgesteld, geen vraag

    @MainActor func test3_MissedCallIsNotSavedProposedOrPrompted() async throws {
        let flow = try await requireFlowE2E()
        var sawRinging = false
        let run = await simulateCall(flow, talk: nil, onRinging: {
            if CallWatcher.shared.current != nil { sawRinging = true }
        })
        XCTAssertTrue(sawRinging, "CallWatcher zag de rinkelende oproep niet (dan test dit niets)")
        XCTAssertFalse(run.promptWhileRinging, "vraag getoond voor een gemiste oproep")
        XCTAssertTrue(run.finished)
        XCTAssertNil(CallWatcher.shared.current)
        XCTAssertTrue(callRecords().isEmpty, "gemiste oproep bewaard: \(callRecords())")
        let plan = await reloadPlan()
        XCTAssertTrue(plan.proposals.filter(\.isCall).isEmpty, "gemiste oproep voorgesteld: \(describe(plan.proposals))")
        XCTAssertTrue(E2EFakeTeamleader.adds.isEmpty)
    }

    // MARK: - d. Hoofdvenster, tabbladen, blok-popover en menubalkpaneel in hun echte containers

    @MainActor func test4_MainWindowTabsAndPopoverSurviveRealLayout() throws {
        try requireBasics()
        let (lo, _) = Store.dayBounds(Date())
        let nowT = Date().timeIntervalSince1970
        if nowT - lo > 20 * 60 {
            // Werk voor Janssen vandaag, plus een gesprek: dan staan er kaarten met blokken op het scherm.
            let from = max(lo + 60, nowT - 2 * 3600)
            let to = min(nowT - 60, from + 3600)
            Database.shared.run("INSERT INTO activity(start, end, app, bundle, title, host) VALUES (?,?,?,?,?,?)",
                                from, to, "Google Chrome", "com.google.Chrome", "Janssen – offerte", "janssen.be")
            Store.save(CallRecord(start: to - 300, end: to - 120, kind: .phone, label: Self.number, detail: "Matthias · M&M",
                                  memoryKey: Self.memoryKey, companyId: "c-mm", companyName: "M&M", confirmed: true))
        }
        if !Store.companies().contains(where: { $0.id == "c-janssen" }) {
            Store.replaceCompanies(E2EFakeTeamleader.companies.map {
                Company(id: $0.id, name: $0.name, domains: $0.website.isEmpty ? [] : [$0.website],
                        phones: $0.phones.compactMap(Phone.key))
            })
        }
        AppModel.shared.tab = 0
        DayModel.shared.day = Date()

        // Het echte hoofdvenster, precies zoals de app het opent.
        let delegate = AppDelegate()
        Self.appDelegate = delegate
        delegate.showMainWindow()
        pump(2)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "TimeTrack" && $0.isVisible },
                                   "hoofdvenster niet gevonden")
        let initial = window.frame
        print("E2E: hoofdvenster \(initial)")
        XCTAssertGreaterThanOrEqual(initial.width, 1000)
        XCTAssertGreaterThanOrEqual(initial.height, 680)
        for tab in [1, 2, 3, 0, 3, 1, 0] {
            AppModel.shared.tab = tab
            pump(1.2)
            XCTAssertTrue(window.isVisible, "venster verdwenen na tab \(tab)")
            XCTAssertEqual(window.frame.width, initial.width, accuracy: 2, "breedte veranderde na tab \(tab): \(window.frame)")
            XCTAssertEqual(window.frame.height, initial.height, accuracy: 2, "hoogte veranderde na tab \(tab): \(window.frame)")
        }

        // Een blok op een voorstelkaart aanklikken opent de echte popover (BlockAssignView).
        AppModel.shared.tab = 0
        pump(2)
        let root = try XCTUnwrap(window.contentView)
        let chip = E2EUIDriver.elements(in: root).first { e in
            let t = E2EUIDriver.text(e)
            return t.range(of: #"\d{1,2}[:.]\d{2}.*–"#, options: .regularExpression) != nil && E2EUIDriver.canPress(e)
        }
        var popoverWindow: NSWindow?
        if let chip {
            print("E2E: blok aanklikken: \(E2EUIDriver.text(chip))")
            E2EUIDriver.press(chip)
            pump(1.5)
            popoverWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
            XCTAssertNotNil(popoverWindow, "geen popover na het aanklikken van een blok")
        } else {
            print("E2E: geen klikbaar blok gevonden (AX-boom van SwiftUI niet beschikbaar?); popover zelf getoond")
            let part = Proposal.Part(start: nowT - 3600, end: nowT - 1800)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: AnyView(
                BlockAssignView(part: part, current: "", pieces: [
                    Proposal.Piece(start: part.start, end: part.start + 900, label: "Chrome: janssen.be"),
                    Proposal.Piece(start: part.start + 900, end: part.end, label: "Claude: offerte"),
                ]) {}.environmentObject(Teamleader.shared)))
            popover.show(relativeTo: NSRect(x: 200, y: 200, width: 10, height: 10), of: root, preferredEdge: .maxY)
            pump(1)
            popoverWindow = popover.contentViewController?.view.window
        }
        if let popoverWindow, let content = popoverWindow.contentView {
            // Een klant zoeken en kiezen in de popover: de inhoud wisselt (zoekresultaten), zoals bij de crash.
            if let field = E2EUIDriver.textFields(in: content).first {
                E2EUIDriver.type("Jans", into: field, window: popoverWindow)
                pump(1.2)
                if let hit = E2EUIDriver.elements(in: content).first(where: { E2EUIDriver.text($0) == "Janssen NV" && E2EUIDriver.canPress($0) }) {
                    E2EUIDriver.press(hit)
                    pump(0.8)
                    if let assign = E2EUIDriver.elements(in: content).first(where: { E2EUIDriver.text($0) == "Toewijzen" && E2EUIDriver.canPress($0) }) {
                        E2EUIDriver.press(assign)
                        pump(2)
                        let (lo2, hi2) = Store.dayBounds(Date())
                        XCTAssertFalse(Store.assignments(from: lo2, to: hi2).isEmpty, "Toewijzen in de popover bewaarde niets")
                    }
                } else {
                    print("E2E: zoekresultaat 'Janssen NV' niet gevonden in de popover")
                }
            }
            pump(0.5)
        }
        XCTAssertEqual(window.frame.width, initial.width, accuracy: 2, "venster veranderde van grootte door de popover")

        // Het menubalkpaneel (MenuBarExtra .window) in een eigen paneel.
        let menu = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 340, height: 420),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.contentView = NSHostingView(rootView: MenuContent(open: {})
            .environmentObject(Tracker.shared).environmentObject(Teamleader.shared))
        menu.orderFrontRegardless()
        pump(1.5)
        XCTAssertTrue(menu.isVisible)
        menu.orderOut(nil)

        window.close()
        pump(0.5)
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Voorwaarden

    @MainActor private func requireBasics() throws {
        guard Self.enabled else {
            throw skip("E2E uitgeschakeld: zet TIMETRACK_E2E=1 (CI doet dat in de stap 'Tests').")
        }
        guard Self.hasDataDir else {
            throw skip("TIMETRACK_DATA_DIR ontbreekt: weigert de echte database van deze Mac te gebruiken.")
        }
        _ = NSApplication.shared
        guard NSScreen.main != nil, !NSScreen.screens.isEmpty else {
            throw skip("geen window server/scherm beschikbaar (NSScreen.main == nil).")
        }
    }

    @MainActor private func requireFlowE2E() async throws -> E2EFakeFlow {
        try requireBasics()
        guard AXIsProcessTrusted() else {
            throw skip("Accessibility is NIET toegekend aan het testproces (AXIsProcessTrusted() == false). "
                + "Zonder die toestemming kan CallWatcher Flow niet lezen. Zie E2E/README.md (grant-accessibility.sh). "
                + "Ouderketen:\n" + Self.processChain())
        }
        guard Tracker.shared.hasAccessibility else {
            throw skip("AXIsProcessTrusted() is true, maar Tracker.shared.hasAccessibility is false "
                + "(Tracker.shared werd aangemaakt vóór de toekenning; enkel Tracker.tick() werkt dat bij).")
        }
        let flow = try await ensureFakeFlow()
        flow.set("ringing")
        var readable = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 300_000_000)
            if FlowReader.parse(await Self.readFlowTexts())?.ringing == true { readable = true; break }
        }
        flow.set("idle")
        guard readable else {
            let texts = await Self.readFlowTexts()
            throw skip("de nep-Flow draait maar FlowReader leest geen rinkelende oproep (\(texts.count) teksten: "
                + texts.prefix(20).joined(separator: " | ") + ").")
        }
        try await ensureTeamleader()
        try await settleWatcher(flow)
        return flow
    }

    @MainActor private func ensureFakeFlow() async throws -> E2EFakeFlow {
        if let flow = Self.fakeFlow, flow.app?.isTerminated == false { return flow }
        guard let url = E2EFakeFlow.locateApp() else {
            throw skip("nep-Flow niet gevonden op \(E2EFakeFlow.defaultAppURL.path): draai ./E2E/build-fakeflow.sh vóór swift test "
                + "(of zet TIMETRACK_FAKEFLOW_APP).")
        }
        let flow = E2EFakeFlow(appURL: url)
        try await flow.launch()
        // NSWorkspace.runningApplications wordt bijgewerkt op de run loop.
        for _ in 0..<50 where FlowReader.app()?.processIdentifier != flow.app?.processIdentifier {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard FlowReader.app() != nil else {
            throw skip("nep-Flow gestart, maar FlowReader.app() vindt geen app met localizedName \"Flow\" "
                + "(gevonden: \(flow.app?.localizedName ?? "?")).")
        }
        Self.fakeFlow = flow
        return flow
    }

    /// Teamleader.shared verbinden met de nep-Teamleader, langs de echte weg (portaal + timetrack://callback).
    @MainActor private func ensureTeamleader() async throws {
        let tl = Teamleader.shared
        if !tl.isConnected {
            _ = try await ensureFakeFlow()     // de nep-Flow vangt het "openen in de browser" op
            UserDefaults.standard.set(false, forKey: "useCustomClient")
            tl.portalURL = "timetrack-e2e://portal"
            E2EFakeFlow.clearOpenedURLs()
            let connect = Task { @MainActor in try await Teamleader.shared.connect() }
            var opened: URL?
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if let url = E2EFakeFlow.openedURLs().last(where: { $0.path.hasSuffix("/timetrack/koppel") }) {
                    opened = url
                    break
                }
            }
            guard let opened,
                  let state = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems?
                      .first(where: { $0.name == "state" })?.value else {
                tl.cancelConnect()
                _ = try? await connect.value
                throw skip("Teamleader kon niet verbonden worden: de koppel-URL (timetrack-e2e://…) kwam niet aan bij de "
                    + "nep-Flow (LaunchServices?). Oplossing: kleine testhaak in Sources, zie E2E/README.md "
                    + "(storeTokens internal maken).")
            }
            var callback = URLComponents(string: "timetrack://callback")!
            callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "ticket", value: "e2e-ticket")]
            tl.handleOpenURL(callback.url!)
            try await connect.value
            Self.connectedByUs = true
        }
        guard tl.isConnected else { throw skip("Teamleader.shared is niet verbonden.") }
        try await tl.refreshProfile()
        try await tl.syncCompanies(force: true)
        XCTAssertTrue(Store.companies().contains { $0.id == "c-mm" }, "bedrijven van de nep-Teamleader niet ingeladen")
        XCTAssertFalse(E2EFakeTeamleader.endpoints.contains { $0.hasPrefix("?") },
                       "onbekende endpoints: \(E2EFakeTeamleader.endpoints.filter { $0.hasPrefix("?") })")
    }

    /// Geen lopend gesprek meer in CallWatcher (bv. na een eerdere, mislukte test).
    @MainActor private func settleWatcher(_ flow: E2EFakeFlow) async throws {
        flow.set("idle")
        if CallWatcher.shared.current != nil {
            _ = await runWatcher(for: 15) { CallWatcher.shared.current == nil }
            CallWatcher.shared.dismissPrompt()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func skip(_ reason: String) -> XCTSkip {
        print("E2E-SKIP: \(name): \(reason)")
        return XCTSkip(reason)
    }

    // MARK: - Een gesprek naspelen

    struct CallRun {
        var ringAt: Double
        var answerAt: Double?
        var hangAt: Double
        var promptWhileRinging = false
        var promptAfterAnswer = false
        var promptHiddenAfterChoice = false
        var choseViaUI = false
        var finished = false
    }

    /// Rinkelt ~6 s, neemt op (talk != nil) en hangt na `talk` seconden op; daarna tot CallWatcher afsluit.
    /// `answer` bedient de vraag (geeft true terug als dat via de echte knoppen lukte).
    @MainActor private func simulateCall(_ flow: E2EFakeFlow, ring: Double = 6, talk: Double?,
                                         onRinging: (() -> Void)? = nil,
                                         answer: (() async -> Bool)? = nil) async -> CallRun {
        flow.set("ringing")
        var run = CallRun(ringAt: now(), hangAt: 0)
        var promptWhileRinging = false
        _ = await runWatcher(for: ring) {
            if self.promptVisible { promptWhileRinging = true }
            onRinging?()
            return false
        }
        guard let talk else {
            flow.set("gone")
            run.hangAt = now()
            let finished = await runWatcher(for: 15) {
                if self.promptVisible { promptWhileRinging = true }
                return CallWatcher.shared.current == nil
            }
            run.finished = finished
            run.promptWhileRinging = promptWhileRinging
            return run
        }
        run.promptWhileRinging = promptWhileRinging
        flow.set("active")
        let answerAt = now()
        run.answerAt = answerAt
        let appeared = await runWatcher(for: 10) { self.promptVisible }
        run.promptAfterAnswer = appeared
        if run.promptAfterAnswer, let panel = promptPanel {
            XCTAssertEqual(panel.frame.width, CallPrompt.size.width, accuracy: 1, "vraag niet op vaste breedte")
            XCTAssertEqual(panel.contentView?.frame.height ?? 0, CallPrompt.size.height, accuracy: 1, "vraag niet op vaste hoogte")
        }
        if let answer {
            let viaUI = await answer()
            run.choseViaUI = viaUI
            let hidden = await runWatcher(for: 3) { !self.promptVisible }
            run.promptHiddenAfterChoice = hidden
        }
        _ = await runWatcher(for: max(0, answerAt + talk - now()))
        flow.set("gone")
        run.hangAt = now()
        let finished = await runWatcher(for: 15) { CallWatcher.shared.current == nil }
        run.finished = finished
        return run
    }

    /// Roept CallWatcher.tick() aan zoals zijn eigen lus (maar elke seconde), tot `until` true geeft of de tijd om is.
    @MainActor @discardableResult
    private func runWatcher(for seconds: Double, every: Double = 1, until: (() -> Bool)? = nil) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            await CallWatcher.shared.tick()
            // Even de run loop laten draaien (CallPrompt.hide gebeurt via DispatchQueue.main.async).
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let until, until() { return true }
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, every - 0.05) * 1_000_000_000))
        } while Date() < end
        return until?() ?? true
    }

    // MARK: - De vraag rechtsboven bedienen zoals een gebruiker

    @MainActor private var promptPanel: NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first { String(describing: type(of: $0)).contains("KeyPanel") }
    }

    @MainActor private var promptVisible: Bool { promptPanel?.isVisible ?? false }

    /// "Andere klant" (als er een voorstel staat) → zoeken → resultaat → "Opslaan". Lukt de UI niet, dan
    /// CallWatcher.choose (en false). Precies het pad waarop de app eerder crashte.
    @MainActor private func chooseInPrompt(companySearch: String, companyName: String) async -> Bool {
        defer { if CallWatcher.shared.current?.confirmed != true { CallWatcher.shared.choose(Self.mm) } }
        guard let panel = promptPanel, panel.isVisible, let root = panel.contentView else { return false }
        if CallWatcher.shared.suggestion != nil {
            guard await pressInPrompt("Andere klant") else { print("E2E: knop 'Andere klant' niet gevonden"); return false }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let field = E2EUIDriver.textFields(in: root).first else {
            print("E2E: zoekveld in de vraag niet gevonden")
            return false
        }
        E2EUIDriver.type(companySearch, into: field, window: panel)
        guard await pressInPrompt(companyName, timeout: 4) else {
            print("E2E: zoekresultaat '\(companyName)' niet gevonden; teksten: \(E2EUIDriver.elements(in: root).map(E2EUIDriver.text).filter { !$0.isEmpty })")
            return false
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard await pressInPrompt("Opslaan") else { print("E2E: knop 'Opslaan' niet gevonden"); return false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return CallWatcher.shared.current?.confirmed == true || CallWatcher.shared.current == nil
    }

    @MainActor private func pressInPrompt(_ label: String, timeout: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let root = promptPanel?.contentView,
               let hit = E2EUIDriver.elements(in: root).first(where: { E2EUIDriver.text($0) == label && E2EUIDriver.canPress($0) }) {
                E2EUIDriver.press(hit)
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        return false
    }

    // MARK: - Controles

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func callRecords() -> [CallRecord] {
        let (lo, hi) = Store.dayBounds(Date())
        return Store.calls(from: lo - 3600, to: hi).filter { $0.memoryKey == Self.memoryKey }.sorted { $0.start < $1.start }
    }

    @MainActor private func reloadPlan() async -> DayPlan {
        DayModel.shared.day = Date()
        await DayModel.shared.reload()
        return DayModel.shared.plan
    }

    private func describe(_ proposals: [Proposal]) -> String {
        proposals.map { "\($0.isCall ? "gesprek" : "werk") \($0.match.companyName) \(formatTime($0.start))–\(formatTime($0.end)) \(Int($0.seconds))s" }
            .joined(separator: "; ")
    }

    /// Begin = het moment van opnemen (niet het rinkelen), einde = ophangen; de klant die gekozen werd.
    private func assertRecord(_ r: CallRecord, answeredAt: Double, hungUpAt: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.start, answeredAt - 0.5, "begin vóór het opnemen (rinkelen meegeteld?)", file: file, line: line)
        XCTAssertLessThanOrEqual(r.start, answeredAt + 3.5, "begin te laat na het opnemen", file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.end, hungUpAt - 3, "einde te vroeg", file: file, line: line)
        XCTAssertLessThanOrEqual(r.end, hungUpAt + 1.5, "einde na het ophangen", file: file, line: line)
        XCTAssertEqual(r.companyId, "c-mm", file: file, line: line)
        XCTAssertTrue(r.confirmed, "gesprek niet als bevestigd bewaard", file: file, line: line)
        XCTAssertEqual(r.kind, .phone, file: file, line: line)
        XCTAssertEqual(r.label, Self.number, file: file, line: line)
    }

    /// Eigen registratie met de echte begintijd en de echte duur, op de minuut naar boven.
    private func assertProposal(_ p: Proposal, for r: CallRecord, file: StaticString = #filePath, line: UInt = #line) {
        let expected = max(60, ((r.end - r.start) / 60).rounded(.up) * 60)
        XCTAssertTrue(p.isCall, file: file, line: line)
        XCTAssertEqual(p.match.companyId, "c-mm", file: file, line: line)
        XCTAssertEqual(p.start, r.start, accuracy: 0.01, "voorstel begint niet op het echte begin van het gesprek", file: file, line: line)
        XCTAssertEqual(p.seconds, expected, accuracy: 0.01,
                       "duur \(Int(p.seconds)) s i.p.v. \(Int(expected)) s voor een gesprek van \(Int(r.end - r.start)) s",
                       file: file, line: line)
        XCTAssertEqual(p.parts.count, 1, "gesprek over meerdere blokken verdeeld: \(p.parts)", file: file, line: line)
        XCTAssertFalse(p.bundled, "gesprek gebundeld met ander werk", file: file, line: line)
    }

    private func assertAdd(_ add: [String: Any], for r: CallRecord, file: StaticString = #filePath, line: UInt = #line) {
        // Naar Teamleader gaat de duur naar boven afgerond op 10 min (3 min bellen = 10 min).
        let expected = Int(Prefs.billed(max(60, ((r.end - r.start) / 60).rounded(.up) * 60)))
        let started = (add["started_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }?.timeIntervalSince1970
        XCTAssertNotNil(started, "geen started_at: \(add)", file: file, line: line)
        if let started {
            XCTAssertEqual(started, r.start.rounded(.down), accuracy: 1.01,
                           "Teamleader kreeg een ander begin (\(add["started_at"] ?? "")) dan het gesprek", file: file, line: line)
        }
        XCTAssertEqual((add["duration"] as? NSNumber)?.intValue, expected, "duur in Teamleader: \(add)", file: file, line: line)
        let subject = add["subject"] as? [String: Any]
        XCTAssertEqual(subject?["type"] as? String, "company", file: file, line: line)
        XCTAssertEqual(subject?["id"] as? String, "c-mm", file: file, line: line)
    }

    // MARK: - Hulpjes

    @MainActor private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func readFlowTexts() async -> [String] {
        await Task.detached { FlowReader.app().map { FlowReader.texts(of: $0) } ?? [] }.value
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "(\(error.localizedDescription))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// pid → ouder → … met hun programma (TCC kijkt naar het "verantwoordelijke" proces in deze keten).
    static func processChain() -> String {
        var pid = Int(getpid())
        var lines: [String] = []
        for _ in 0..<15 where pid > 1 {
            let out = shell("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(pid)"])
            let parts = out.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let parent = Int(parts[0]) else { break }
            lines.append("  \(pid): \(parts[1])")
            pid = parent
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Nep-Teamleader (in dit proces, via URLProtocol)

/// Beantwoordt alle verzoeken naar api.focus.teamleader.eu en de portaal-endpoints /api/timetrack/token|refresh
/// (ook op het schema timetrack-e2e://). Houdt elke timeTracking.add bij en geeft die terug in timeTracking.list.
final class E2EFakeTeamleader: URLProtocol {
    struct FakeCompany {
        let id: String
        let name: String
        var website = ""
        var phones: [String] = []
    }

    static let companies: [FakeCompany] = [
        FakeCompany(id: "c-mm", name: "M&M", website: "mm-events.be", phones: ["+32 493 29 50 63"]),
        FakeCompany(id: "c-janssen", name: "Janssen NV", website: "janssen.be", phones: ["+32 56 11 09 59"]),
        FakeCompany(id: "c-peeters", name: "Bakkerij Peeters BV", website: "bakkerijpeeters.be"),
    ]

    private static let lock = NSLock()
    private static var _adds: [[String: Any]] = []
    private static var _registrations: [[String: Any]] = []
    private static var _endpoints: [String] = []
    private static var nextId = 1

    static var adds: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _adds }
    /// Alle aangesproken endpoints, in volgorde; "?x" = onbekend endpoint x.
    static var endpoints: [String] { lock.lock(); defer { lock.unlock() }; return _endpoints }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _adds = []
        _registrations = []
        _endpoints = []
    }

    static func handles(_ url: URL?) -> Bool {
        guard let url else { return false }
        let host = url.host ?? ""
        return host == "api.focus.teamleader.eu" || host == "focus.teamleader.eu" || url.scheme == "timetrack-e2e"
            || url.path.hasPrefix("/api/timetrack/")
    }

    override class func canInit(with request: URLRequest) -> Bool { handles(request.url) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.bodyData(request)
        let json = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        let (status, payload) = Self.respond(url, json)
        let data = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private static func page(_ json: [String: Any]) -> Int {
        ((json["page"] as? [String: Any])?["number"] as? NSNumber)?.intValue ?? 1
    }

    private static func dict(_ c: FakeCompany) -> [String: Any] {
        ["id": c.id, "name": c.name, "website": c.website, "emails": [[String: Any]](),
         "telephones": c.phones.map { ["type": "phone", "number": $0] }]
    }

    private static func respond(_ url: URL, _ json: [String: Any]) -> (Int, [String: Any]?) {
        let endpoint = url.host == "api.focus.teamleader.eu" ? String(url.path.drop { $0 == "/" }) : url.path
        lock.lock(); defer { lock.unlock() }
        switch endpoint {
        case "/api/timetrack/token", "/api/timetrack/refresh", "/oauth2/access_token":
            _endpoints.append(endpoint)
            return (200, ["access_token": "e2e-access-\(UUID().uuidString)", "refresh_token": "e2e-refresh",
                          "expires_in": 3600, "token_type": "Bearer"])
        case "users.me":
            _endpoints.append(endpoint)
            let me: [String: Any] = ["id": "u-e2e", "first_name": "E2E", "last_name": "Tester", "email": "e2e@mtea.be",
                                     "preferences": ["invoiceable": true]]
            return (200, ["data": me])
        case "workTypes.list":
            _endpoints.append(endpoint)
            let types: [[String: String]] = page(json) == 1 ? [["id": "wt-call", "name": "Telefoon"]] : []
            return (200, ["data": types])
        case "companies.list":
            _endpoints.append(endpoint)
            var list = companies
            if let term = (json["filter"] as? [String: Any])?["term"] as? String, !term.isEmpty {
                list = list.filter { $0.name.lowercased().contains(term.lowercased()) }
            }
            let data: [[String: Any]] = page(json) == 1 ? list.map(dict) : []
            return (200, ["data": data])
        case "companies.info":
            _endpoints.append(endpoint)
            guard let c = companies.first(where: { $0.id == json["id"] as? String }) else {
                return (404, ["errors": [["title": "company not found"]]])
            }
            return (200, ["data": dict(c)])
        case "companies.update":
            _endpoints.append(endpoint)
            return (204, nil)
        case "contacts.list":
            _endpoints.append(endpoint)
            return (200, ["data": [[String: Any]]()])
        case "contacts.info":
            _endpoints.append(endpoint)
            let contact: [String: Any] = ["id": json["id"] ?? "", "companies": [[String: Any]]()]
            return (200, ["data": contact])
        case "timeTracking.list":
            _endpoints.append(endpoint)
            let data: [[String: Any]] = page(json) == 1 ? _registrations : []
            return (200, ["data": data])
        case "timeTracking.add":
            _endpoints.append(endpoint)
            // Zoals de echte Teamleader: een lege omschrijving of een duur zonder minuten wordt geweigerd.
            if let d = json["description"], (d as? String)?.isEmpty ?? true {
                _adds.append(json)
                return (400, ["errors": [["status": 400, "title": "description must be null"]]])
            }
            guard (json["duration"] as? NSNumber)?.intValue ?? 0 > 0, json["started_at"] is String else {
                _adds.append(json)
                return (400, ["errors": [["status": 400, "title": "started_at and duration are required"]]])
            }
            let id = "tt-\(nextId)"
            nextId += 1
            _adds.append(json)
            _registrations.append(["id": id, "started_at": json["started_at"] ?? NSNull(),
                                   "duration": json["duration"] ?? 0, "subject": json["subject"] ?? NSNull(),
                                   "description": json["description"] ?? ""])
            return (201, ["data": ["id": id, "type": "timeTracking"]])
        case "timeTracking.delete":
            _endpoints.append(endpoint)
            _registrations.removeAll { $0["id"] as? String == json["id"] as? String }
            return (204, nil)
        default:
            _endpoints.append("?" + endpoint)
            return (404, ["errors": [["title": "E2E-nep-Teamleader: onbekend endpoint \(endpoint)"]]])
        }
    }
}

// MARK: - Nep-Flow besturen

final class E2EFakeFlow {
    static let bundleId = "be.mtea.timetrack.e2e.fakeflow"
    /// Vast pad: ook een nog draaiende nep-Flow van een vorige run luistert hier.
    static let controlDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("timetrack-e2e-fakeflow", isDirectory: true)

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var defaultAppURL: URL { packageRoot.appendingPathComponent("E2E/build/Flow.app") }

    static func locateApp() -> URL? {
        if let path = ProcessInfo.processInfo.environment["TIMETRACK_FAKEFLOW_APP"], !path.isEmpty {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return FileManager.default.fileExists(atPath: defaultAppURL.path) ? defaultAppURL : nil
    }

    let appURL: URL
    private(set) var app: NSRunningApplication?

    init(appURL: URL) { self.appURL = appURL }

    func set(_ state: String, number: String = EndToEndTests.number, name: String = "Matthias .", company: String = "M&M") {
        let text = "state=\(state)\nnumber=\(number)\nname=\(name)\ncompany=\(company)\n"
        try? text.write(to: Self.controlDir.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    }

    @MainActor func launch() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.controlDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: Self.controlDir.appendingPathComponent("fakeflow.ready"))
        set("idle")
        // Een achtergebleven exemplaar van een vorige run eerst stoppen.
        for old in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId) { old.forceTerminate() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--control", Self.controlDir.path]
        config.environment = ["FAKEFLOW_CONTROL": Self.controlDir.path]
        config.activates = false
        config.createsNewApplicationInstance = false
        let url = appURL
        app = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let app { cont.resume(returning: app) } else {
                    cont.resume(throwing: error ?? NSError(domain: "E2E", code: 1,
                                                           userInfo: [NSLocalizedDescriptionKey: "nep-Flow niet gestart"]))
                }
            }
        }
        let ready = Self.controlDir.appendingPathComponent("fakeflow.ready")
        for _ in 0..<75 where !fm.fileExists(atPath: ready.path) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard fm.fileExists(atPath: ready.path) else {
            throw NSError(domain: "E2E", code: 2, userInfo: [NSLocalizedDescriptionKey: "nep-Flow meldde zich niet klaar"])
        }
    }

    func quit() {
        set("quit")
        Thread.sleep(forTimeInterval: 0.3)
        if app?.isTerminated == false { app?.terminate() }
    }

    static func clearOpenedURLs() {
        try? FileManager.default.removeItem(at: controlDir.appendingPathComponent("openurl.txt"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fakeflow-openurl.txt"))
    }

    static func openedURLs() -> [URL] {
        let files = [controlDir.appendingPathComponent("openurl.txt"),
                     URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fakeflow-openurl.txt")]
        return files.flatMap { file -> [URL] in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return text.split(whereSeparator: \.isNewline).compactMap { URL(string: String($0)) }
        }
    }
}

// MARK: - SwiftUI bedienen via de toegankelijkheidsobjecten in dit proces (geen IPC, dus geen deadlock)

@MainActor
enum E2EUIDriver {
    private static func get(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    /// Alle toegankelijkheidselementen onder een view (SwiftUI-knoppen, teksten…), diepte-eerst.
    static func elements(in root: NSView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, _ depth: Int) {
            guard depth < 40, out.count < 5000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            out.append(object)
            for child in (get(object, "accessibilityChildren") as? [Any]) ?? [] {
                if let child = child as? NSObject { walk(child, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    static func text(_ object: NSObject) -> String {
        for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            if let s = get(object, key) as? String, !s.isEmpty { return s }
        }
        return ""
    }

    static func canPress(_ object: NSObject) -> Bool {
        guard object.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
        let role = get(object, "accessibilityRole") as? String ?? ""
        return role == "AXButton" || role == "AXLink" || role == "AXMenuButton" || role == "AXPopUpButton"
            || role == "AXCell" || role.isEmpty
    }

    static func press(_ object: NSObject) {
        _ = object.perform(NSSelectorFromString("accessibilityPerformPress"))
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField, field.isEditable, !field.isHidden { out.append(field) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    /// Typt zoals het toetsenbord: via de field editor, zodat SwiftUI's binding en .task(id:) meekomen.
    static func type(_ text: String, into field: NSTextField, window: NSWindow) {
        window.makeKey()
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
    }
}
