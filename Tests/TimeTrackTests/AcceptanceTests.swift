import XCTest
@testable import TimeTrack

/// Acceptatietests: elke test is een eis van de eigenaar, uitgeschreven als een realistische dag.
/// Bewust tegendraads: zoeken naar tijd die verloren gaat, dubbel telt, in de toekomst doorloopt,
/// bij de verkeerde klant belandt of een voorstel dat verdwijnt.
///
/// Gesprekken: elk gesprek is een EIGEN voorstel (nooit gebundeld met ander werk voor die klant), met zijn
/// echte begin- en eindtijd en een duur op de minuut naar boven (niet op 5 of 15 min).
final class AcceptanceTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27))!
    private let janssen = Company(id: "c-janssen", name: "Janssen NV", domains: ["janssen.be"])
    private let peeters = Company(id: "c-peeters", name: "Bakkerij Peeters BV", domains: ["bakkerijpeeters.be"])
    private let klantX = Company(id: "c-klantx", name: "Klant X", domains: ["klantx.be"])

    override func setUp() {
        super.setUp()
        let db = Database.shared
        for table in ["activity", "rules", "dismissed", "companies", "pushed", "calls", "call_memory", "assignments"] {
            db.run("DELETE FROM \(table)")
        }
        Store.replaceCompanies([janssen, peeters, klantX])
    }

    // MARK: - Hulpjes

    /// Tijdstip op de testdag (of een andere dag), bv. t(13, 30) of t(10, 0, 20).
    private func t(_ h: Int, _ m: Int = 0, _ s: Int = 0, on date: Date? = nil) -> Double {
        let base = date ?? day
        if (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s),
           let exact = Calendar.current.date(bySettingHour: h, minute: m, second: s, of: base) {
            return exact.timeIntervalSince1970
        }
        // Minuten of seconden buiten het bereik (bv. 9u64): optellen vanaf middernacht.
        return Calendar.current.startOfDay(for: base).timeIntervalSince1970 + Double(h * 3600 + m * 60 + s)
    }

    private var nextDay: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }

    private func activity(_ from: Double, _ to: Double, app: String = "Google Chrome", title: String = "", host: String = "") {
        Database.shared.run("INSERT INTO activity(start, end, app, bundle, title, host) VALUES (?,?,?,?,?,?)",
                            from, to, app, "", title, host)
    }

    private func matcher(ownNames: [String] = []) -> Matcher {
        Matcher(ownDomain: "mtea.be", excluded: [], ownNames: ownNames)
    }

    private func plan(on date: Date? = nil, registered: [Registered] = [], roundTo: Int = 1,
                      events: [CalendarEvent] = [], bundle: Bool = false, calls: [CallRecord] = [],
                      ownNames: [String] = []) -> DayPlan {
        Planner.plan(day: date ?? day, registered: registered, matcher: matcher(ownNames: ownNames), roundTo: roundTo,
                     events: events, bundle: bundle, calls: calls)
    }

    private func hms(_ t: Double) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: t))
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private func describe(_ p: DayPlan) -> String {
        "\n" + p.proposals.map { pr in
            "\(hms(pr.start))–\(hms(pr.end)) \(pr.match.isAssigned ? pr.match.companyName : "?") \(Int(pr.seconds))s "
                + "parts=\(pr.parts.map { "\(hms($0.start))–\(hms($0.end))" }) act=\(pr.activities)"
        }.joined(separator: "\n")
    }

    private func phoneCall(_ start: Double, _ end: Double, _ company: Company?, number: String = "0493 29 50 63",
                           confirmed: Bool = true) -> CallRecord {
        CallRecord(start: start, end: end, kind: .phone, label: number, detail: "Piet · \(company?.name ?? "?")",
                   memoryKey: "tel:" + (Phone.key(number) ?? number), companyId: company?.id,
                   companyName: company?.name ?? "", confirmed: confirmed)
    }

    private func isPhone(_ p: Proposal) -> Bool { p.activities.contains { $0.hasPrefix("Telefoon: ") } }
    private func phoneProposals(_ p: DayPlan) -> [Proposal] { p.proposals.filter(isPhone) }
    private func proposals(_ p: DayPlan, _ c: Company) -> [Proposal] { p.proposals.filter { $0.match.companyId == c.id } }
    private func partSeconds(_ p: Proposal) -> Double { p.parts.reduce(0) { $0 + $1.end - $1.start } }

    private func overlaps(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { a.0 < b.1 - 0.001 && b.0 < a.1 - 0.001 }

    /// Eén voorstel voor dit gesprek, met de echte tijden en de duur op de minuut naar boven.
    private func assertCallBookedExactly(_ plan: DayPlan, _ call: CallRecord, file: StaticString = #filePath, line: UInt = #line) {
        let expectedSeconds = max(60, ((call.end - call.start) / 60).rounded(.up) * 60)
        let hits = plan.proposals.filter { $0.start == call.start }
        XCTAssertEqual(hits.count, 1, "gesprek \(hms(call.start))–\(hms(call.end)) moet precies één eigen voorstel zijn"
                       + describe(plan), file: file, line: line)
        guard let hit = hits.first else { return }
        XCTAssertEqual(hit.match.companyId, call.companyId, "klant van het gesprek", file: file, line: line)
        XCTAssertEqual(hit.parts, [Proposal.Part(start: call.start, end: call.end)],
                       "het blok is het echte gesprek, niet de minuutgrenzen of meer" + describe(plan), file: file, line: line)
        XCTAssertEqual(hit.seconds, expectedSeconds, accuracy: 0.5,
                       "duur = gesprek op de minuut naar boven" + describe(plan), file: file, line: line)
        XCTAssertFalse(hit.bundled, "een gesprek wordt nooit gebundeld", file: file, line: line)
    }

    /// Structurele eisen die voor ELKE dag moeten gelden.
    private func assertInvariants(_ plan: DayPlan, registeredTimed: [(Double, Double)] = [], dismissed: [(Double, Double)] = [],
                                  latestInput: Double, on date: Date? = nil, context: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let (lo, hi) = Store.dayBounds(date ?? day)
        let limit = (latestInput / 60).rounded(.up) * 60
        var all: [(Double, Double, String)] = []
        for p in plan.proposals {
            XCTAssertFalse(p.match.skip, "genegeerd werk wordt nooit voorgesteld \(context)", file: file, line: line)
            XCTAssertGreaterThan(p.seconds, 0, "voorstel zonder duur \(context)", file: file, line: line)
            XCTAssertFalse(p.parts.isEmpty, "voorstel zonder blokken \(context)", file: file, line: line)
            for part in p.parts {
                XCTAssertLessThan(part.start, part.end, "leeg of omgekeerd blok \(context)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(part.start, lo, "blok voor het begin van de dag \(context)", file: file, line: line)
                XCTAssertLessThanOrEqual(part.end, hi, "blok na het einde van de dag \(context)", file: file, line: line)
                XCTAssertLessThanOrEqual(part.end, limit + 0.001,
                                         "blok loopt door na de laatste activiteit (toekomst) \(context)" + describe(plan),
                                         file: file, line: line)
                for r in registeredTimed where overlaps((part.start, part.end), r) {
                    XCTFail("voorstel \(hms(part.start))–\(hms(part.end)) overlapt registratie \(hms(r.0))–\(hms(r.1)) \(context)"
                            + describe(plan), file: file, line: line)
                }
                for d in dismissed where overlaps((part.start, part.end), d) {
                    XCTFail("voorstel \(hms(part.start))–\(hms(part.end)) overlapt genegeerd blok \(context)",
                            file: file, line: line)
                }
                all.append((part.start, part.end, p.id))
            }
        }
        all.sort { $0.0 < $1.0 }
        for i in all.indices.dropFirst() where all[i].0 < all[i - 1].1 - 0.001 {
            XCTFail("dubbel voorgestelde tijd: \(hms(all[i].0)) zit in twee voorstellen \(context)" + describe(plan),
                    file: file, line: line)
        }
    }

    // MARK: - 1 + 4. Automatisch voorstellen, met de reden erbij

    func testR4_GapWithClientWebsiteProposesThatClientBecauseOfTheSite() {
        // Seconden zoals de tracker ze schrijft (elke 5 s), niet netjes op de minuut.
        activity(t(13, 0, 17), t(14, 59, 41), host: "klantx.be")
        let p = plan(roundTo: 5)
        XCTAssertEqual(p.proposals.count, 1, describe(p))
        let x = try? XCTUnwrap(p.proposals.first)
        XCTAssertEqual(x?.match.companyId, "c-klantx")
        XCTAssertEqual(x?.start, t(13))
        XCTAssertEqual(x?.end, t(15))
        XCTAssertEqual(x?.seconds ?? 0, 7200, accuracy: 1)
        XCTAssertTrue(x?.reasons.first?.hasPrefix("website klantx.be") ?? false, "\(x?.reasons ?? [])")
    }

    func testR1_MailAndDocumentsAreRecognisedPerClient() {
        activity(t(9), t(9, 20), app: "Mail", title: "Re: planning oplevering – Klant X")
        activity(t(9, 20), t(9, 50), app: "Microsoft Word", title: "Offerte Bakkerij Peeters v2.docx")
        let p = plan()
        XCTAssertEqual(p.proposals.map(\.match.companyId), ["c-klantx", "c-peeters"], describe(p))
        XCTAssertEqual(p.proposals.first?.end, t(9, 20))
        XCTAssertEqual(p.proposals.last?.start, t(9, 20))
    }

    func testR1_CalendarMeetingWithClientWinsOverOtherLaptopWork() {
        activity(t(10), t(11), host: "bakkerijpeeters.be")   // tijdens het overleg stond de site van Peeters open
        let meeting = CalendarEvent(start: t(10), end: t(11), title: "Overleg", attendeeEmails: ["piet@janssen.be"])
        let p = plan(events: [meeting])
        XCTAssertEqual(p.proposals.map(\.match.companyId), ["c-janssen"], describe(p))
        XCTAssertEqual(p.proposals.first?.start, t(10))
        XCTAssertEqual(p.proposals.first?.end, t(11))
    }

    func testR1_UnrecognisedAcceptedMeetingIsStillProposedSoYouCanPickTheClient() {
        activity(t(9, 30), t(9, 50), app: "Finder")
        let webinar = CalendarEvent(start: t(10), end: t(11), title: "Bedrijfswebinar", attendeeEmails: ["x@onbekend.be"])
        let p = plan(events: [webinar])
        let meeting = p.proposals.first { $0.start == t(10) }
        XCTAssertNotNil(meeting, describe(p))
        XCTAssertEqual(meeting?.end, t(11))
        XCTAssertFalse(meeting?.match.isAssigned ?? true)
        XCTAssertEqual(meeting?.description, "Bedrijfswebinar")
    }

    func testR1_OwnFocusBlockInCalendarIsNotWork() {
        let focus = CalendarEvent(start: t(10), end: t(12), title: "Focus", attendeeEmails: [])
        activity(t(9, 50), t(9, 55), app: "Finder")
        let p = plan(events: [focus])
        XCTAssertTrue(p.proposals.allSatisfy { $0.start < t(10) }, describe(p))
    }

    // MARK: - 2. Enkel echt werk (geen inactiviteit, middag, vergrendeling, slaap)

    func testR2_IdleLunchLockAndSleepAreNotWork() {
        activity(t(8, 30), t(12), host: "janssen.be")
        activity(t(12), t(12, 40), app: Store.idleApp)       // inactief
        // 12:40–13:10 niets: vergrendeld / middag
        activity(t(13, 10), t(17), host: "janssen.be")
        // 17:00–18:00 slaapstand: niets
        activity(t(18), t(18, 20), host: "janssen.be")
        let separate = plan()
        XCTAssertEqual(separate.proposals.map { [$0.start, $0.end] },
                       [[t(8, 30), t(12)], [t(13, 10), t(17)], [t(18), t(18, 20)]], describe(separate))
        XCTAssertEqual(separate.worked, (210 + 230 + 20) * 60, accuracy: 1)

        let bundled = plan(roundTo: 15, bundle: true)
        XCTAssertEqual(bundled.proposals.count, 1, describe(bundled))
        let b = bundled.proposals.first
        XCTAssertEqual(b.map(partSeconds) ?? 0, 460 * 60, accuracy: 1, "de blokken zelf bevatten geen pauzes")
        XCTAssertEqual(b?.parts.count, 3)
        XCTAssertLessThanOrEqual(abs((b?.seconds ?? 0) - 460 * 60), 450, "afronden op 15 min wijkt hoogstens 7,5 min af")
        XCTAssertEqual((b?.seconds ?? 1).truncatingRemainder(dividingBy: 900), 0, accuracy: 0.001)
    }

    func testR2_IdleInsideABlockIsNotCountedAsWork() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(10, 6), app: Store.idleApp)
        activity(t(10, 6), t(11), host: "janssen.be")
        let p = plan(bundle: true)
        XCTAssertEqual(p.worked, 114 * 60, accuracy: 1)
        XCTAssertEqual(p.proposals.first.map(partSeconds) ?? 0, 114 * 60, accuracy: 1, describe(p))
    }

    func testR2_OverlappingTrackerRowsAreNotCountedTwice() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(9), t(10), host: "janssen.be")      // zelfde blok twee keer weggeschreven
        activity(t(9, 30), t(10), app: "Mail", title: "Re: Janssen")
        let p = plan()
        XCTAssertEqual(p.worked, 3600, accuracy: 1)
        XCTAssertEqual(p.proposedSeconds, 3600, accuracy: 1, describe(p))
    }

    func testR2_VideoBetweenClientWorkIsResearchForThatClient() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(10, 25), title: "Tutorial formulieren - YouTube - Google Chrome - Matthias", host: "youtube.com")
        activity(t(10, 25), t(11), host: "bakkerijpeeters.be")
        let p = plan()
        XCTAssertTrue(p.proposals.allSatisfy(\.match.isAssigned), "de video hoort bij een klant" + describe(p))
        XCTAssertEqual(p.proposedSeconds, 7200, accuracy: 1, "geen tijd verloren")
        XCTAssertEqual(proposals(p, janssen).first?.end, t(10, 25), "video na Janssen-werk → Janssen" + describe(p))
        XCTAssertEqual(proposals(p, peeters).first?.start, t(10, 25))
    }

    func testR2_VideoJustBeforeClientWorkGetsThatClient() {
        activity(t(8, 40), t(9), title: "Uitleg Shopify API - YouTube", host: "youtube.com")
        activity(t(9), t(10), host: "janssen.be")
        let p = plan(bundle: true)
        XCTAssertEqual(p.proposals.count, 1, describe(p))
        XCTAssertEqual(p.proposals.first?.match.companyId, "c-janssen")
        XCTAssertEqual(p.proposals.first?.start, t(8, 40))
        XCTAssertTrue(p.proposals.first?.reasons.contains { $0.contains("voor werk voor Janssen NV") } ?? false,
                      "\(p.proposals.first?.reasons ?? [])")
    }

    func testR2_VideoFarFromClientWorkIsStillProposedSoItCanBeAssigned() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(15), t(15, 30), title: "Webinar SEO - YouTube", host: "youtube.com")
        let p = plan()
        let video = p.proposals.first { $0.start == t(15) }
        XCTAssertNotNil(video, "video telt als werk, ook zonder herkende klant" + describe(p))
        XCTAssertEqual(video?.end, t(15, 30))
        XCTAssertFalse(video?.match.isAssigned ?? true)
    }

    // MARK: - 3. Naast Teamleader, nooit dubbel

    func testR3_RegisteredWithStartTimeIsNeverProposedAgain() {
        activity(t(9), t(12), host: "janssen.be")
        let r = Registered(id: "r1", start: t(9), duration: 5400, companyId: "c-janssen", companyName: "Janssen NV", description: "")
        for bundle in [false, true] {
            let p = plan(registered: [r], roundTo: 5, bundle: bundle)
            XCTAssertEqual(p.proposals.count, 1, describe(p))
            XCTAssertEqual(p.proposals.first?.parts, [Proposal.Part(start: t(10, 30), end: t(12))], describe(p))
            XCTAssertEqual(p.proposals.first?.seconds ?? 0, 5400, accuracy: 1)
            XCTAssertEqual(p.registeredSeconds, 5400, accuracy: 1, "het dagplan toont wat al in Teamleader staat")
            assertInvariants(p, registeredTimed: [(t(9), t(10, 30))], latestInput: t(12))
        }
    }

    func testR3_TimeRegisteredForAnotherClientIsAlsoNotProposedAgain() {
        activity(t(9), t(10), host: "janssen.be")
        let r = Registered(id: "r1", start: t(9), duration: 3600, companyId: "c-peeters",
                           companyName: "Bakkerij Peeters BV", description: "met de hand")
        XCTAssertTrue(plan(registered: [r]).proposals.isEmpty, "die tijd staat al in Teamleader: anders dubbel")
    }

    func testR3_RegistrationWithoutStartTimeIsSubtractedExactlyOnce() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(14), t(15), host: "janssen.be")
        let untimed = Registered(id: "r1", start: nil, duration: 3600, companyId: "c-janssen", companyName: "Janssen NV",
                                 description: "", day: "2026-10-27")
        let separate = plan(registered: [untimed])
        XCTAssertEqual(separate.proposedSeconds, 3600, accuracy: 1, describe(separate))
        let bundled = plan(registered: [untimed], bundle: true)
        XCTAssertEqual(bundled.proposals.count, 1, describe(bundled))
        XCTAssertEqual(bundled.proposals.first?.seconds ?? 0, 3600, accuracy: 1)
        XCTAssertEqual(bundled.proposals.first?.parts, [Proposal.Part(start: t(9), end: t(10))])
    }

    func testR3_RegisteredBundleThenNewWorkForSameClientProposesOnlyTheNewWork() {
        activity(t(9), t(9, 30), host: "janssen.be")
        activity(t(9, 30), t(10, 30), host: "bakkerijpeeters.be")
        activity(t(10, 30), t(11), host: "janssen.be")
        Store.savePushed(teamleaderId: "tl-1", parts: [.init(start: t(9), end: t(9, 30)), .init(start: t(10, 30), end: t(11))])
        let r = Registered(id: "tl-1", start: t(9), duration: 3600, companyId: "c-janssen", companyName: "Janssen NV", description: "")
        activity(t(14), t(14, 20), host: "janssen.be")
        let p = plan(registered: [r], bundle: true)
        let j = proposals(p, janssen)
        XCTAssertEqual(j.count, 1, describe(p))
        XCTAssertEqual(j.first?.parts, [Proposal.Part(start: t(14), end: t(14, 20))])
        XCTAssertEqual(j.first?.seconds ?? 0, 1200, accuracy: 1)
        XCTAssertEqual(proposals(p, peeters).first?.seconds ?? 0, 3600, accuracy: 1)
    }

    func testR3_RegistrationDeletedInTeamleaderComesBackAsProposal() {
        activity(t(9), t(10), host: "janssen.be")
        Store.savePushed(teamleaderId: "tl-gone", parts: [.init(start: t(9), end: t(10))])
        let p = plan(registered: [])          // in Teamleader verwijderd
        XCTAssertEqual(p.proposals.first?.parts, [Proposal.Part(start: t(9), end: t(10))], describe(p))
    }

    /// Geregistreerd met afronding (53 min → 1u, in Teamleader 13:00–14:00), daarna nog 7 min voor dezelfde klant
    /// gewerkt. Die 7 min staan al in Teamleader (13:53–14:00 valt in de registratie): niet opnieuw voorstellen,
    /// anders staat er 1u15 voor 1u werk.
    func testR3_RoundedUpRegistrationAlreadyCoversTheNextMinutesOfTheSameClient() {
        activity(t(13), t(13, 53), host: "janssen.be")
        let first = plan(roundTo: 15, bundle: true)
        let p1 = try? XCTUnwrap(first.proposals.first)
        XCTAssertEqual(p1?.seconds ?? 0, 3600, accuracy: 1)
        Store.savePushed(teamleaderId: "tl-r", parts: p1?.parts ?? [])
        let r = Registered(id: "tl-r", start: t(13), duration: 3600, companyId: "c-janssen", companyName: "Janssen NV", description: "")
        activity(t(13, 53), t(14), host: "janssen.be")
        let second = plan(registered: [r], roundTo: 15, bundle: true)
        let extra = proposals(second, janssen).reduce(0) { $0 + $1.seconds }
        XCTAssertEqual(extra, 0, accuracy: 1, "1u gewerkt, 1u geregistreerd: nog eens \(Int(extra / 60)) min voorstellen is dubbel"
                       + describe(second))
    }

    // MARK: - 5. Bundelen per klant, blokken en delen zelf toewijzen

    private func spreadDay() {
        activity(t(6), t(6, 15), host: "janssen.be")
        activity(t(6, 15), t(9), app: "Figma", title: "Ontwerp homepage")
        activity(t(9), t(9, 15), host: "janssen.be")
    }

    func testR5_BundleAddsUpSpreadBlocksOfOneClient() {
        spreadDay()
        for roundTo in [5, 15] {
            let p = plan(roundTo: roundTo, bundle: true)
            let j = proposals(p, janssen)
            XCTAssertEqual(j.count, 1, describe(p))
            XCTAssertEqual(j.first?.seconds ?? 0, 1800, accuracy: 1)
            XCTAssertEqual(j.first?.start, t(6))
            XCTAssertEqual(j.first?.parts, [Proposal.Part(start: t(6), end: t(6, 15)), Proposal.Part(start: t(9), end: t(9, 15))])
            XCTAssertEqual(j.first?.bundled, true)
        }
        let off = plan(roundTo: 15, bundle: false)
        XCTAssertEqual(proposals(off, janssen).map(\.seconds), [900, 900], describe(off))
    }

    func testR5_ClickingABlockOfABundleAndAssigningItToAnotherClient() {
        spreadDay()
        Store.assign(start: t(9), end: t(9, 15), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let p = plan(roundTo: 5, bundle: true)
        XCTAssertEqual(proposals(p, janssen).first?.parts, [Proposal.Part(start: t(6), end: t(6, 15))], describe(p))
        XCTAssertEqual(proposals(p, janssen).first?.seconds ?? 0, 900, accuracy: 1)
        let pe = proposals(p, peeters).first
        XCTAssertEqual(pe?.parts, [Proposal.Part(start: t(9), end: t(9, 15))])
        XCTAssertTrue(pe?.reasons.first?.contains("door jou toegewezen") ?? false)
    }

    func testR5_AssigningAPieceInsideABundledBlock() {
        activity(t(9), t(9, 20), host: "janssen.be")
        activity(t(9, 20), t(9, 40), app: "Microsoft Word", title: "Offerte Janssen.docx")
        activity(t(9, 40), t(11), app: "Figma", title: "Ontwerp")
        activity(t(11), t(11, 30), host: "janssen.be")
        let before = plan(bundle: true)
        let block = proposals(before, janssen).first
        XCTAssertEqual(block?.pieces.count, 3, "binnen de blokken: website, Word, website" + describe(before))
        guard let word = block?.pieces.first(where: { $0.start == t(9, 20) }) else { return XCTFail("geen deel voor Word") }
        XCTAssertEqual(word.end, t(9, 40))
        Store.assign(start: word.start, end: word.end, to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let after = plan(bundle: true)
        XCTAssertEqual(proposals(after, janssen).first?.seconds ?? 0, 50 * 60, accuracy: 1, describe(after))
        XCTAssertEqual(proposals(after, peeters).first?.parts, [Proposal.Part(start: t(9, 20), end: t(9, 40))])
    }

    func testR5_ReassigningPartOfAnAssignedBlockLaterWins() {
        spreadDay()
        Store.assign(start: t(9), end: t(9, 15), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        Store.assign(start: t(9, 5), end: t(9, 10), to: Match(companyId: "c-janssen", companyName: "Janssen NV"))
        let p = plan(roundTo: 5, bundle: true)
        XCTAssertEqual(proposals(p, janssen).first?.seconds ?? 0, 20 * 60, accuracy: 1, describe(p))
        XCTAssertEqual(proposals(p, peeters).first?.seconds ?? 0, 10 * 60, accuracy: 1)
        assertInvariants(p, latestInput: t(9, 15))
    }

    func testR5_DismissingOneBlockOfABundleKeepsTheRest() {
        spreadDay()
        Store.dismiss(start: t(6), end: t(6, 15))
        let p = plan(roundTo: 5, bundle: true)
        XCTAssertEqual(proposals(p, janssen).first?.parts, [Proposal.Part(start: t(9), end: t(9, 15))], describe(p))
        assertInvariants(p, dismissed: [(t(6), t(6, 15))], latestInput: t(9, 15))
        let (lo, hi) = Store.dayBounds(day)
        Store.undismiss(from: lo, to: hi)
        XCTAssertEqual(proposals(plan(roundTo: 5, bundle: true), janssen).first?.seconds ?? 0, 1800, accuracy: 1, "terugzetten")
    }

    func testR5_RoundingStaysWithinHalfAStepAndNeverBelowOneStep() {
        let cases: [(Int, Int)] = [(7, 5), (7, 15), (22, 15), (52, 15), (53, 15), (59, 5), (61, 5), (8, 15)]
        for (minutes, step) in cases {
            setUp()
            activity(t(9), t(9, minutes), host: "janssen.be")
            let s = plan(roundTo: step).proposals.first?.seconds ?? -1
            XCTAssertEqual(s.truncatingRemainder(dividingBy: Double(step * 60)), 0, accuracy: 0.001, "\(minutes) min / \(step)")
            XCTAssertGreaterThanOrEqual(s, Double(step * 60), "\(minutes) min / \(step)")
            if minutes >= step {
                XCTAssertLessThanOrEqual(abs(s - Double(minutes * 60)), Double(step * 30) + 0.001, "\(minutes) min / \(step) → \(s / 60) min")
            }
        }
    }

    // MARK: - 6. AI-chats

    func testR6_ChatWithClientInTitleIsReadableAndRecognised() {
        activity(t(9), t(9, 25), title: "Offerte Bakkerij Peeters herschrijven - Claude - Google Chrome - Matthias", host: "claude.ai")
        let p = plan()
        let chat = p.proposals.first
        XCTAssertEqual(chat?.match.companyId, "c-peeters", describe(p))
        XCTAssertEqual(chat?.learnPattern, "Offerte Bakkerij Peeters herschrijven")
        XCTAssertTrue(chat?.activities.first?.hasPrefix("claude.ai: Offerte Bakkerij Peeters herschrijven") ?? false,
                      "leesbaar: \(chat?.activities ?? [])")
    }

    func testR6_ChatWithoutClientJustBeforeClientWorkGetsThatClient() {
        activity(t(8, 30), t(8, 50), app: "Claude", title: "Tekst herschrijven")
        activity(t(9), t(10), host: "janssen.be")
        let p = plan(bundle: true)
        XCTAssertEqual(p.proposals.count, 1, describe(p))
        XCTAssertEqual(p.proposals.first?.match.companyId, "c-janssen")
        XCTAssertEqual(p.proposals.first?.seconds ?? 0, 80 * 60, accuracy: 1)
        XCTAssertTrue(p.proposals.first?.reasons.contains { $0.hasPrefix("Claude voor werk voor Janssen NV") } ?? false,
                      "\(p.proposals.first?.reasons ?? [])")
    }

    func testR6_ChatBetweenTwoClientsIsNotLost() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(10, 20), title: "Mail opstellen - ChatGPT", host: "chatgpt.com")
        activity(t(10, 20), t(11), host: "bakkerijpeeters.be")
        let p = plan()
        XCTAssertTrue(p.proposals.allSatisfy(\.match.isAssigned), describe(p))
        XCTAssertEqual(p.proposedSeconds, 7200, accuracy: 1)
    }

    func testR6_OnthoudChatTitleRecognisesTheSameChatLater() {
        // Eerst niet herkend: de chattitel is de kandidaat om te onthouden.
        activity(t(11), t(11, 25), title: "Nieuwsbrief november - Claude", host: "claude.ai")
        let before = plan().proposals.first
        XCTAssertFalse(before?.match.isAssigned ?? true)
        let pattern = before?.learnPattern ?? ""
        XCTAssertEqual(pattern, "Nieuwsbrief november")
        // Wat de kaart bij "Onthoud" bewaart (ProposalCard.submit).
        Store.save(Rule(field: "any", pattern: pattern, companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let after = plan().proposals.first
        XCTAssertEqual(after?.match.companyId, "c-peeters")
        XCTAssertTrue(after?.reasons.first?.hasPrefix("regel") ?? false)
        // Ook in de Claude-app zelf, waar enkel een vaste chatnaam bekend is.
        setUp()
        activity(t(11), t(11, 25), app: "Claude", title: "Claude-chat 4f2a91c3")
        Store.save(Rule(field: "any", pattern: "Claude-chat 4f2a91c3", companyId: "c-janssen", companyName: "Janssen NV"))
        XCTAssertEqual(plan().proposals.first?.match.companyId, "c-janssen")
    }

    // MARK: - 7. Chrome-profiel en eigen naam zijn nooit een klant

    func testR7_ChromeProfileNameIsNeverMatched() {
        Store.replaceCompanies([janssen, peeters, Company(id: "c-matthias", name: "Matthias", domains: [])])
        activity(t(9), t(10), title: "TPC Cloud - Google Chrome - Matthias")
        activity(t(10), t(10, 30), title: "Inbox (3) - info@mtea.be - Gmail - Google Chrome - Matthias", host: "mail.google.com")
        let p = plan()
        XCTAssertTrue(p.proposals.allSatisfy { $0.match.companyId != "c-matthias" }, describe(p))
    }

    func testR7_ProfileNameIsAlsoIgnoredInEdgeTitles() {
        // Edge zet het profiel vóór de browsernaam: "Pagina - Profiel - Microsoft Edge".
        Store.replaceCompanies([janssen, Company(id: "c-matthias", name: "Matthias", domains: [])])
        let (m, _) = matcher().match(app: "Microsoft Edge", title: "TPC Cloud - Matthias - Microsoft\u{200B} Edge", host: "")
        XCTAssertFalse(m.isAssigned, "profielnaam in Edge werd als klant herkend: \(m.companyName)")
    }

    func testR7_OwnNameIsNeverAClientAlsoNotViaPhone() {
        Store.replaceCompanies([janssen, Company(id: "c-me", name: "Matthias Rijnwalt", domains: [], phones: ["493295063"])])
        let m = matcher(ownNames: ["Matthias Rijnwalt", "Matthias"])
        XCTAssertFalse(m.match(app: "Mail", title: "Offerte voor Matthias Rijnwalt", host: "").0.isAssigned)
        XCTAssertNil(m.match(phone: "0493 29 50 63", companyHint: "Matthias Rijnwalt"))
    }

    // MARK: - 8. Telefoongesprekken (Flow)

    func testR8_FourMinuteCallStaysFourMinutesWhateverTheRoundingOrBundling() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(10, 5), app: "Flow", title: "Flow")
        activity(t(10, 5), t(11), host: "janssen.be")
        let call = phoneCall(t(10), t(10, 4), janssen)
        for roundTo in [1, 5, 15] {
            for bundle in [false, true] {
                let p = plan(roundTo: roundTo, bundle: bundle, calls: [call])
                assertCallBookedExactly(p, call)
                for other in proposals(p, janssen) where !isPhone(other) {
                    XCTAssertFalse(other.parts.contains { overlaps(($0.start, $0.end), (call.start, call.end)) },
                                   "gesprekstijd zit niet ook in het andere werk (round \(roundTo), bundle \(bundle))" + describe(p))
                }
            }
        }
    }

    func testR8_OneMinuteCallIsBookedAsOneMinute() {
        let call = phoneCall(t(14, 0, 5), t(14, 1), peeters)
        activity(t(14), t(14, 2), app: "Flow", title: "Flow")
        let p = plan(roundTo: 15, bundle: true, calls: [call])
        assertCallBookedExactly(p, call)
    }

    func testR8_SecondCallOneMinuteLaterWithSameNumberIsItsOwnProposal() {
        let first = phoneCall(t(10), t(10, 3, 30), janssen)
        let second = phoneCall(t(10, 4, 30), t(10, 6), janssen)
        activity(t(10), t(10, 7), app: "Flow", title: "Flow")
        let p = plan(roundTo: 5, bundle: true, calls: [first, second])
        assertCallBookedExactly(p, first)
        assertCallBookedExactly(p, second)
        XCTAssertEqual(phoneProposals(p).count, 2, describe(p))
    }

    func testR8_SecondCallIsStillProposedAfterTheFirstWasRegistered() {
        let first = phoneCall(t(10), t(10, 3, 30), janssen)
        let second = phoneCall(t(10, 4, 30), t(10, 6), janssen)
        activity(t(10), t(10, 7), app: "Flow", title: "Flow")
        // Het eerste gesprek werd geregistreerd: in Teamleader 10:00–10:04 (afgerond op de minuut).
        Store.savePushed(teamleaderId: "tl-c1", parts: [.init(start: first.start, end: first.end)])
        let r = Registered(id: "tl-c1", start: first.start, duration: 240, companyId: "c-janssen", companyName: "Janssen NV", description: "")
        let p = plan(registered: [r], roundTo: 5, bundle: true, calls: [first, second])
        XCTAssertEqual(p.proposals.count, 1, describe(p))
        assertCallBookedExactly(p, second)
    }

    func testR8_BackToBackCallsInTheSameMinuteKeepTheirOwnTime() {
        let first = phoneCall(t(10), t(10, 2, 30), janssen)
        let second = phoneCall(t(10, 2, 45), t(10, 4), peeters, number: "056 11 09 59")
        activity(t(10), t(10, 4), app: "Flow", title: "Flow")
        let p = plan(roundTo: 5, bundle: true, calls: [first, second])
        assertCallBookedExactly(p, first)     // 2 min 30 s → 3 min, niet 2
        assertCallBookedExactly(p, second)
    }

    func testR8_BackToBackCallAfterRegisteringTheFirstKeepsItsRealStart() {
        let first = phoneCall(t(10), t(10, 2, 30), janssen)
        let second = phoneCall(t(10, 2, 45), t(10, 4, 45), janssen)
        activity(t(10), t(10, 5), app: "Flow", title: "Flow")
        Store.savePushed(teamleaderId: "tl-c1", parts: [.init(start: first.start, end: first.end)])
        let r = Registered(id: "tl-c1", start: first.start, duration: 180, companyId: "c-janssen", companyName: "Janssen NV", description: "")
        let p = plan(registered: [r], roundTo: 5, bundle: true, calls: [first, second])
        assertCallBookedExactly(p, second)
    }

    func testR8_CallForAnotherClientWhileBrowsingKeepsTheCallSeparate() {
        activity(t(10), t(10, 30), host: "janssen.be")
        let call = phoneCall(t(10, 10), t(10, 14), peeters)
        let p = plan(bundle: true, calls: [call])
        assertCallBookedExactly(p, call)
        let j = proposals(p, janssen).first
        XCTAssertEqual(j?.parts, [Proposal.Part(start: t(10), end: t(10, 10)), Proposal.Part(start: t(10, 14), end: t(10, 30))],
                       describe(p))
        XCTAssertEqual((j?.seconds ?? 0) + (phoneProposals(p).first?.seconds ?? 0), 1800, accuracy: 1, "niets dubbel, niets kwijt")
    }

    func testR8_CallWithoutKnownClientIsStillItsOwnProposal() {
        // Niet beantwoord in de vraag, nummer onbekend: het gesprek moet er toch staan, om een klant te kiezen.
        activity(t(10), t(10, 30), host: "janssen.be")
        let call = phoneCall(t(10, 10), t(10, 16), nil, number: "0470 12 34 56", confirmed: false)
        let p = plan(bundle: true, calls: [call])
        let hit = p.proposals.first { $0.start == call.start }
        XCTAssertNotNil(hit, "gesprek zonder klant verdween in het werk voor Janssen" + describe(p))
        XCTAssertEqual(hit?.parts, [Proposal.Part(start: call.start, end: call.end)])
        XCTAssertFalse(hit?.match.isAssigned ?? true)
    }

    func testR8_ZeroLengthOrMissedCallIsNotWork() {
        // Gemist / enkel even gezien: geen duur. Telt niet, ook niet als 1 minuut.
        activity(t(10), t(10, 1), app: "Flow", title: "Flow")
        let missed = phoneCall(t(10, 0, 30), t(10, 0, 30), janssen, confirmed: false)
        let p = plan(calls: [missed])
        XCTAssertTrue(p.proposals.isEmpty, describe(p))
        XCTAssertEqual(p.worked, 0, accuracy: 1, "een gemist gesprek is geen gewerkte tijd")
    }

    func testR8_TimeInFlowOutsideTheCallIsNotWork() {
        activity(t(10), t(10, 30), app: "Flow", title: "Flow")
        let call = phoneCall(t(10, 5), t(10, 11), janssen)
        let p = plan(roundTo: 15, bundle: true, calls: [call])
        XCTAssertEqual(p.proposals.count, 1, describe(p))
        assertCallBookedExactly(p, call)
        XCTAssertEqual(p.worked, 360, accuracy: 1)
    }

    func testR8_PrivateCallIsNotProposedAndNotMergedIntoClientWork() {
        activity(t(9, 30), t(10), host: "janssen.be")
        activity(t(10), t(10, 10), app: "Flow", title: "Flow")
        activity(t(10, 10), t(10, 40), host: "janssen.be")
        var call = phoneCall(t(10), t(10, 10), nil)
        call.skip = true
        let p = plan(bundle: true, calls: [call])
        XCTAssertEqual(p.proposals.count, 1, describe(p))
        XCTAssertEqual(p.proposals.first?.parts, [Proposal.Part(start: t(9, 30), end: t(10)), Proposal.Part(start: t(10, 10), end: t(10, 40))])
    }

    func testR8_ChatRightAfterACallGetsTheClientButDoesNotStretchTheCall() {
        let call = phoneCall(t(10), t(10, 10), janssen)
        activity(t(10), t(10, 10), app: "Flow", title: "Flow")
        activity(t(10, 10), t(10, 25), app: "Claude", title: "Verslag gesprek")
        let p = plan(bundle: true, calls: [call])
        assertCallBookedExactly(p, call)
        let chat = p.proposals.filter { !isPhone($0) }
        XCTAssertEqual(chat.reduce(0) { $0 + $1.seconds }, 15 * 60, accuracy: 1, "de chat staat apart" + describe(p))
        XCTAssertTrue(chat.allSatisfy { $0.match.companyId == "c-janssen" }, "chat na een gesprek met Janssen → Janssen" + describe(p))
    }

    func testR8_ShortUnrecognisedWorkAfterACallDoesNotStretchTheCall() {
        let call = phoneCall(t(10), t(10, 20), janssen)
        activity(t(10), t(10, 20), app: "Flow", title: "Flow")
        activity(t(10, 20), t(10, 26), app: "Figma", title: "Ontwerp")
        let p = plan(bundle: false, calls: [call])
        assertCallBookedExactly(p, call)
    }

    func testR8_ShortWorkForAnotherClientAfterACallDoesNotStretchTheCall() {
        let call = phoneCall(t(10), t(10, 20), janssen)
        activity(t(10), t(10, 20), app: "Flow", title: "Flow")
        activity(t(10, 20), t(10, 23), host: "bakkerijpeeters.be")
        let p = plan(bundle: false, calls: [call])
        assertCallBookedExactly(p, call)
    }

    func testR8_CallAcrossMidnightIsSplitOverBothDaysWithoutLoss() {
        let call = phoneCall(t(23, 58), t(0, 3, on: nextDay), janssen)
        let today = plan(roundTo: 15, calls: [call])
        let tomorrow = plan(on: nextDay, roundTo: 15, calls: [call])
        let a = phoneProposals(today).first, b = phoneProposals(tomorrow).first
        XCTAssertEqual(a?.start, t(23, 58), describe(today))
        XCTAssertEqual(a?.end, t(0, 0, on: nextDay))
        XCTAssertEqual(b?.start, t(0, 0, on: nextDay), describe(tomorrow))
        XCTAssertEqual((a?.seconds ?? 0) + (b?.seconds ?? 0), 300, accuracy: 1)
    }

    func testR8_FlowPanelIsReadForOutgoingInternationalCall() {
        let texts = ["Beschikbaar", "Uitgaande oproep", "01:12", "J.", "Jan Peeters", "Bakkerij Peeters", "+32 56 11 09 59",
                     "Via", "Mtea - Verkoop", "Ophangen", "Parkeren"]
        let call = FlowReader.parse(texts)
        XCTAssertEqual(call?.number, "+32 56 11 09 59")
        XCTAssertEqual(call?.key, "tel:" + (Phone.key("+32 56 11 09 59") ?? "?"))
        XCTAssertEqual(call?.ringing, false)
        XCTAssertEqual(call?.companyHint, "Bakkerij Peeters")
        XCTAssertEqual(Matcher(excluded: [], ownNames: []).match(phone: call?.number ?? "", companyHint: call?.companyHint ?? "")?.0.companyId,
                       "c-peeters", "bedrijfsnaam uit Flow wordt herkend")
    }

    func testR8_LandlineNumberMatchesInNationalAndInternationalNotation() {
        // Belgische vaste nummers hebben 8 cijfers na de 0 (056 11 09 59), gsm-nummers 9 (0493 29 50 63).
        // Flow toont "056 11 09 59", Teamleader bewaart vaak "+32 56 11 09 59": dat is hetzelfde nummer.
        XCTAssertEqual(Phone.key("056 11 09 59"), Phone.key("+32 56 11 09 59"))
        XCTAssertEqual(Phone.key("056 11 09 59"), Phone.key("0032 56 11 09 59"))
        Store.replaceCompanies([Company(id: "c-peeters", name: "Bakkerij Peeters BV", domains: [],
                                        phones: [Phone.key("+32 56 11 09 59")!])])
        XCTAssertEqual(matcher().match(phone: "056 11 09 59")?.0.companyId, "c-peeters")
    }

    func testR8_AnswerIsRememberedPerNumberAndLatestAnswerWins() {
        let key = "tel:" + Phone.key("+32 493 29 50 63")!
        Store.remember(key, Match(companyId: "c-janssen", companyName: "Janssen NV"))
        XCTAssertEqual(Store.callMemory("tel:" + Phone.key("0493/29.50.63")!)?.companyId, "c-janssen", "zelfde nummer, andere schrijfwijze")
        Store.remember(key, Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        XCTAssertEqual(Store.callMemory(key)?.companyId, "c-peeters")
    }

    func testR8_NumberAddedToCompanyIsRecognisedOnTheNextCall() {
        XCTAssertNil(matcher().match(phone: "0470 12 34 56"))
        Store.addCompanyPhone(companyId: "c-klantx", key: Phone.key("0470 12 34 56")!)
        XCTAssertEqual(matcher().match(phone: "+32 470 12 34 56")?.0.companyId, "c-klantx")
    }

    // MARK: - 9. Meetings

    func testR9_MeetingWithClientIsItsOwnExactProposalWithItsTitle() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(14), t(14, 45), app: "Microsoft Teams", title: "Microsoft Teams")
        let event = CalendarEvent(start: t(14), end: t(14, 45), title: "Weekoverleg", attendeeEmails: ["piet@janssen.be"])
        let meeting = CallRecord(start: t(14), end: t(14, 45), kind: .meeting, label: "Weekoverleg", detail: "Teams-gesprek",
                                 memoryKey: "meet:weekoverleg", companyId: "c-janssen", companyName: "Janssen NV", confirmed: true)
        let p = plan(roundTo: 15, events: [event], bundle: true, calls: [meeting])
        let j = proposals(p, janssen)
        XCTAssertEqual(j.count, 2, "meeting apart van het andere werk voor Janssen" + describe(p))
        let m = j.first { $0.start == t(14) }
        XCTAssertEqual(m?.parts, [Proposal.Part(start: t(14), end: t(14, 45))])
        XCTAssertEqual(m?.seconds ?? 0, 2700, accuracy: 1)
        XCTAssertEqual(m?.description, "Weekoverleg")
    }

    func testR9_GenericTeamsCallIsNeverRememberedForAllCalls() {
        Store.remember("", Match(companyId: "c-janssen", companyName: "Janssen NV"))
        XCTAssertNil(Store.callMemory(""), "een los 'Teams-gesprek' (zonder agenda-titel) mag niets onthouden")
        XCTAssertNotEqual("meet:" + Matcher.normalize("Weekoverleg Janssen"), "meet:" + Matcher.normalize("Teams-gesprek"))
    }

    func testR9_UnrecognisedMeetingIsProposedUnassigned() {
        activity(t(15), t(15, 30), app: "zoom.us", title: "Zoom Meeting")
        let meeting = CallRecord(start: t(15), end: t(15, 30), kind: .meeting, label: "Zoom-meeting")
        let p = plan(roundTo: 15, calls: [meeting])
        let m = p.proposals.first { $0.start == t(15) }
        XCTAssertNotNil(m, describe(p))
        XCTAssertFalse(m?.match.isAssigned ?? true)
        XCTAssertEqual(m?.parts, [Proposal.Part(start: t(15), end: t(15, 30))])
    }

    // MARK: - 10. Privé

    func testR10_WipeRemovesAllTrackedActivityButKeepsRules() {
        activity(t(9), t(10), host: "janssen.be")
        Store.save(phoneCall(t(10), t(10, 4), janssen))
        Store.dismiss(start: t(11), end: t(12))
        Store.assign(start: t(9), end: t(9, 30), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        Store.save(Rule(field: "any", pattern: "youtube.com", skip: true))
        Store.wipeActivity()
        for table in ["activity", "calls", "dismissed", "assignments"] {
            XCTAssertEqual(Database.shared.query("SELECT COUNT(*) AS n FROM \(table)").first?.int("n"), 0, table)
        }
        XCTAssertEqual(Store.rules().count, 1)
        XCTAssertFalse(Database.directory.path.contains("Mobile Documents"), "activiteit nooit in iCloud Drive")
    }

    // MARK: - 11. Vlot

    func testR11_FullBusyDayIsPlannedQuickly() {
        let contexts: [(String, String, String)] = [
            ("Google Chrome", "Dashboard", "janssen.be"), ("Microsoft Word", "Offerte Bakkerij Peeters.docx", ""),
            ("Figma", "Ontwerp", ""), ("Claude", "Tekst herschrijven", ""), ("Mail", "Re: Klant X planning", ""),
            ("Google Chrome", "Video - YouTube", "youtube.com"), ("Slack", "general", ""),
        ]
        var calls: [CallRecord] = []
        Database.shared.transaction {
            var s = t(8)
            var i = 0
            while s < t(17) {
                let c = contexts[(i / 6 + i % 3) % contexts.count]
                activity(s, s + 5, app: c.0, title: "\(c.1)", host: c.2)
                s += 5
                i += 1
            }
        }
        for h in 9...16 { calls.append(phoneCall(t(h, 10, 7), t(h, 13, 2), janssen)) }
        for bundle in [false, true] {
            let started = Date()
            let p = plan(roundTo: 5, bundle: bundle, calls: calls)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 1.5, "dagvoorstel voor een volle dag duurt \(elapsed) s (bundle \(bundle))")
            assertInvariants(p, latestInput: t(17), context: "drukke dag")
        }
    }

    // MARK: - Grenzen van de dag

    func testMidnightActivityIsSplitOverBothDays() {
        activity(t(23, 30), t(0, 30, on: nextDay), host: "janssen.be")
        let a = plan().proposals.first, b = plan(on: nextDay).proposals.first
        XCTAssertEqual(a?.start, t(23, 30))
        XCTAssertEqual(a?.end, Store.dayBounds(day).1)
        XCTAssertEqual(b?.start, t(0, 0, on: nextDay))
        XCTAssertEqual(b?.end, t(0, 30, on: nextDay))
    }

    private func withBrussels(_ body: () throws -> Void) throws {
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Europe/Brussels")!
        defer { NSTimeZone.default = original }
        guard Calendar.current.timeZone.identifier == "Europe/Brussels" else {
            throw XCTSkip("Calendar.current volgt NSTimeZone.default niet op deze Mac")
        }
        try body()
    }

    func testDSTFallBackDayOf25HoursKeepsExactTimes() throws {
        try withBrussels {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
            let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
            let (lo, hi) = Store.dayBounds(d)
            XCTAssertEqual(hi - lo, 25 * 3600, accuracy: 1)
            activity(lo + 5400, lo + 12600, host: "janssen.be")              // 01:30 CEST → 02:30 CET: 2 echte uren
            activity(lo + 23 * 3600, lo + 24 * 3600, host: "bakkerijpeeters.be") // 22:00–23:00 CET
            let p = plan(on: d)
            let j = proposals(p, janssen).first, pe = proposals(p, peeters).first
            XCTAssertEqual(j?.start, lo + 5400, describe(p))
            XCTAssertEqual(j?.seconds ?? 0, 7200, accuracy: 1)
            XCTAssertEqual(pe?.start, lo + 23 * 3600)
            XCTAssertEqual(pe.map { cal.component(.hour, from: Date(timeIntervalSince1970: $0.start)) }, 22)
            XCTAssertEqual(p.worked, 3 * 3600, accuracy: 1)
        }
    }

    func testDSTSpringForwardDayOf23HoursKeepsExactTimes() throws {
        try withBrussels {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
            let d = cal.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))!
            let (lo, hi) = Store.dayBounds(d)
            XCTAssertEqual(hi - lo, 23 * 3600, accuracy: 1)
            activity(lo + 3600, lo + 3 * 3600, host: "janssen.be")             // 01:00 CET → 04:00 CEST
            activity(lo + 21 * 3600, lo + 22 * 3600, host: "bakkerijpeeters.be") // 22:00–23:00 CEST
            let p = plan(on: d)
            XCTAssertEqual(proposals(p, janssen).first?.seconds ?? 0, 7200, accuracy: 1, describe(p))
            XCTAssertEqual(proposals(p, peeters).first.map { cal.component(.hour, from: Date(timeIntervalSince1970: $0.start)) }, 22)
        }
    }

    // MARK: - Een rommelige dag: alles door elkaar

    func testMessyDayKeepsEveryStructuralGuarantee() {
        activity(t(7, 58, 40), t(8, 31, 10), app: "Mail", title: "Re: offerte – Klant X")
        activity(t(8, 31, 10), t(8, 33), title: "Nieuw tabblad")
        activity(t(8, 33), t(9, 12, 55), host: "janssen.be")
        activity(t(9, 12, 55), t(9, 15), title: "Sport - YouTube", host: "youtube.com")
        activity(t(9, 15), t(9, 40), app: "Claude", title: "Tekst herschrijven")
        activity(t(9, 40), t(10), app: "Flow", title: "Flow")
        activity(t(10), t(10, 47), app: "Microsoft Word", title: "Offerte Bakkerij Peeters.docx")
        activity(t(10, 47), t(11, 30), app: Store.idleApp)
        activity(t(12, 30), t(13, 4), host: "bakkerijpeeters.be")
        activity(t(13, 4), t(13, 8), host: "janssen.be")
        activity(t(13, 8), t(14, 2), app: "Figma", title: "Ontwerp")
        activity(t(14, 2), t(15, 30), title: "TPC Cloud - Google Chrome - Matthias")
        activity(t(15, 30), t(16, 15), host: "klantx.be")
        Store.save(Rule(field: "any", pattern: "sport - youtube", skip: true))
        Store.dismiss(start: t(14, 2), end: t(14, 30))
        Store.assign(start: t(13, 8), end: t(13, 30), to: Match(companyId: "c-klantx", companyName: "Klant X"))
        let registered = [
            Registered(id: "r1", start: t(8, 40), duration: 1200, companyId: "c-janssen", companyName: "Janssen NV", description: ""),
            Registered(id: "r2", start: nil, duration: 900, companyId: "c-peeters", companyName: "Bakkerij Peeters BV",
                       description: "", day: "2026-10-27"),
        ]
        let calls = [phoneCall(t(9, 41, 12), t(9, 44, 50), janssen), phoneCall(t(9, 46), t(9, 52, 30), peeters),
                     phoneCall(t(15, 40), t(15, 42), nil, confirmed: false)]
        let events = [CalendarEvent(start: t(11), end: t(12), title: "Overleg", attendeeEmails: ["piet@janssen.be"])]
        for roundTo in [1, 5, 15] {
            for bundle in [false, true] {
                let p = plan(registered: registered, roundTo: roundTo, events: events, bundle: bundle, calls: calls)
                assertInvariants(p, registeredTimed: [(t(8, 40), t(9))], dismissed: [(t(14, 2), t(14, 30))],
                                 latestInput: t(16, 15), context: "round \(roundTo) bundle \(bundle)")
                XCTAssertTrue(p.proposals.allSatisfy { $0.match.companyName != "Matthias" })
            }
        }
    }

    // MARK: - Willekeurige dagen (vaste zaden, herhaalbaar)

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let randomContexts: [(String, String, String)] = [
        ("Google Chrome", "Dashboard", "janssen.be"), ("Microsoft Word", "Offerte Bakkerij Peeters.docx", ""),
        ("Mail", "Re: planning – Klant X", ""), ("Figma", "Ontwerp", ""), ("Claude", "Tekst herschrijven", ""),
        ("Google Chrome", "Uitleg - YouTube", "youtube.com"), (Store.idleApp, "", ""), ("", "", ""),
        ("Flow", "Flow", ""), ("Google Chrome", "TPC Cloud - Google Chrome - Matthias", ""),
    ]

    /// Willekeurige activiteit van 7:00 tot ~19:00; geeft het einde van de laatste activiteit terug.
    private func randomDay(_ rng: inout SeededRNG) -> Double {
        var s = t(7) + Double(Int.random(in: 0..<600, using: &rng))
        var last = s
        Database.shared.transaction {
            while s < t(19) {
                let c = randomContexts[Int.random(in: 0..<randomContexts.count, using: &rng)]
                let long = Bool.random(using: &rng)
                let length = Double(Int.random(in: 10...(long ? 2400 : 300), using: &rng))
                if !c.0.isEmpty {
                    activity(s, s + length, app: c.0, title: c.1, host: c.2)
                    if c.0 != Store.idleApp { last = s + length }
                }
                s += length
            }
        }
        return last
    }

    func testRandomDaysKeepEveryStructuralGuarantee() {
        for seed in 1...25 {
            setUp()
            var rng = SeededRNG(state: UInt64(seed))
            var latest = randomDay(&rng)
            var registeredTimed: [(Double, Double)] = []
            var registered: [Registered] = []
            for k in 0..<2 {
                let s = t(8) + Double(Int.random(in: 0..<36000, using: &rng))
                let d = Double(Int.random(in: 5...90, using: &rng) * 60)
                registered.append(Registered(id: "r\(k)", start: s, duration: d, companyId: "c-janssen", companyName: "Janssen NV", description: ""))
                registeredTimed.append((s, s + d))
            }
            registered.append(Registered(id: "u", start: nil, duration: 1800, companyId: "c-peeters", companyName: "Bakkerij Peeters BV",
                                         description: "", day: "2026-10-27"))
            let ds = t(8) + Double(Int.random(in: 0..<36000, using: &rng))
            let dismissed = (ds, ds + Double(Int.random(in: 1...40, using: &rng) * 60))
            Store.dismiss(start: dismissed.0, end: dismissed.1)
            let asg = t(8) + Double(Int.random(in: 0..<36000, using: &rng))
            Store.assign(start: asg, end: asg + 900, to: Match(companyId: "c-klantx", companyName: "Klant X"))
            var calls: [CallRecord] = []
            var cs = t(8)
            for _ in 0..<4 {
                cs += Double(Int.random(in: 600...7200, using: &rng))
                let ce = cs + Double(Int.random(in: 15...900, using: &rng))
                calls.append(phoneCall(cs, ce, Bool.random(using: &rng) ? janssen : peeters))
                latest = max(latest, ce)
                cs = ce
            }
            for roundTo in [1, 15] {
                for bundle in [false, true] {
                    let p = plan(registered: registered, roundTo: roundTo, bundle: bundle, calls: calls)
                    assertInvariants(p, registeredTimed: registeredTimed, dismissed: [dismissed], latestInput: latest,
                                     context: "seed \(seed) round \(roundTo) bundle \(bundle)")
                }
            }
        }
    }

    /// Gesprekken midden in willekeurig werk: elk gesprek blijft één eigen voorstel met zijn echte tijd.
    func testRandomDaysEveryCallIsBookedExactly() {
        var failures: [String] = []
        for seed in 101...130 {
            setUp()
            var rng = SeededRNG(state: UInt64(seed))
            _ = randomDay(&rng)
            var calls: [CallRecord] = []
            var cs = t(8)
            for _ in 0..<5 {
                cs += Double(Int.random(in: 60...5400, using: &rng))       // minstens 1 min tussen gesprekken
                let ce = cs + Double(Int.random(in: 20...900, using: &rng))
                calls.append(phoneCall(cs, ce, [janssen, peeters, klantX][Int.random(in: 0..<3, using: &rng)]))
                cs = ce
            }
            let bundle = Bool.random(using: &rng)
            let roundTo = [1, 5, 15][Int.random(in: 0..<3, using: &rng)]
            let p = plan(roundTo: roundTo, bundle: bundle, calls: calls)
            for call in calls {
                let expected = max(60, ((call.end - call.start) / 60).rounded(.up) * 60)
                let hits = p.proposals.filter { $0.start == call.start }
                if hits.count != 1 || hits[0].parts != [Proposal.Part(start: call.start, end: call.end)]
                    || abs(hits[0].seconds - expected) > 0.5 || hits[0].match.companyId != call.companyId {
                    failures.append("seed \(seed) (round \(roundTo), bundle \(bundle)): gesprek \(hms(call.start))–\(hms(call.end)) "
                                    + "\(call.companyName) → \(hits.map { "\(hms($0.start))–\(hms($0.end)) \(Int($0.seconds))s" })")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) gesprekken niet exact geboekt, bv.:\n" + failures.prefix(8).joined(separator: "\n"))
    }
}
