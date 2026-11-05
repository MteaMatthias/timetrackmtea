import XCTest
@testable import TimeTrack

final class PlannerTests: XCTestCase {
    private let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27))!
    private let janssen = Company(id: "c-janssen", name: "Janssen NV", domains: ["janssen.be"])
    private let peeters = Company(id: "c-peeters", name: "Bakkerij Peeters BV", domains: ["bakkerijpeeters.be"])

    override func setUp() {
        super.setUp()
        let db = Database.shared
        db.run("DELETE FROM activity")
        db.run("DELETE FROM rules")
        db.run("DELETE FROM dismissed")
        db.run("DELETE FROM companies")
        db.run("DELETE FROM pushed")
        db.run("DELETE FROM calls")
        db.run("DELETE FROM call_memory")
        db.run("DELETE FROM assignments")
        Store.replaceCompanies([janssen, peeters])
    }

    /// Tijdstip op de testdag, bv. t(13, 30).
    private func t(_ h: Int, _ m: Int = 0) -> Double {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)!.timeIntervalSince1970
    }

    private func activity(_ from: Double, _ to: Double, app: String = "Google Chrome", title: String = "", host: String = "") {
        Database.shared.run("INSERT INTO activity(start, end, app, bundle, title, host) VALUES (?,?,?,?,?,?)",
                            from, to, app, "", title, host)
    }

    private func plan(registered: [Registered] = [], roundTo: Int = 1, events: [CalendarEvent] = [],
                      bundle: Bool = false, calls: [CallRecord] = []) -> DayPlan {
        Planner.plan(day: day, registered: registered, matcher: Matcher(ownDomain: "mtea.be", excluded: []),
                     roundTo: roundTo, events: events, bundle: bundle, calls: calls)
    }

    func testWebsiteVisitBecomesProposalWithReason() {
        activity(t(13), t(15), host: "janssen.be")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        let proposal = try! XCTUnwrap(p.proposals.first)
        XCTAssertEqual(proposal.start, t(13))
        XCTAssertEqual(proposal.end, t(15))
        XCTAssertEqual(proposal.match.companyId, "c-janssen")
        XCTAssertTrue(proposal.reasons.first?.contains("website janssen.be") ?? false, "\(proposal.reasons)")
        XCTAssertEqual(p.worked, 2 * 3600, accuracy: 1)
    }

    func testSubdomainMatchesCompanyDomain() {
        activity(t(9), t(10), host: "shop.janssen.be")
        XCTAssertEqual(plan().proposals.first?.match.companyId, "c-janssen")
    }

    func testRegisteredTimeIsNotProposedAgain() {
        activity(t(13), t(15), host: "janssen.be")
        let registered = Registered(id: "r1", start: t(13), duration: 3600, companyId: "c-janssen",
                                    companyName: "Janssen NV", description: "")
        let p = plan(registered: [registered])
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.start, t(14))
        XCTAssertEqual(p.proposals.first?.end, t(15))
    }

    func testIdleTimeIsNotWork() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(11), app: Store.idleApp)
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.end, t(10))
        XCTAssertEqual(p.worked, 3600, accuracy: 1)
    }

    func testShortInterruptionIsAbsorbed() {
        activity(t(13), t(14), host: "janssen.be")
        activity(t(14), t(14, 3), app: "Slack", title: "general")
        activity(t(14, 3), t(15), host: "janssen.be")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1, "\(p.proposals.map { "\($0.start)-\($0.end) \($0.match.companyName)" })")
        XCTAssertEqual(p.proposals.first?.start, t(13))
        XCTAssertEqual(p.proposals.first?.end, t(15))
    }

    func testShortBreakIsBridged() {
        activity(t(13), t(14), host: "janssen.be")
        activity(t(14, 2), t(15), host: "janssen.be")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.end, t(15))
    }

    func testTwoClientsGiveTwoProposals() {
        activity(t(9), t(11), host: "janssen.be")
        activity(t(11), t(12), app: "Microsoft Word", title: "Offerte Bakkerij Peeters.docx")
        let p = plan()
        XCTAssertEqual(p.proposals.map(\.match.companyId), ["c-janssen", "c-peeters"])
        XCTAssertEqual(p.proposals.last?.start, t(11))
    }

    func testCompanyNameInWindowTitle() {
        let (match, reason) = Matcher(excluded: []).match(app: "Microsoft Word", title: "Offerte Bakkerij Peeters v3.docx", host: "")
        XCTAssertEqual(match.companyId, "c-peeters")
        XCTAssertTrue(reason.contains("Bakkerij Peeters"))
    }

    func testNameMustMatchWholeWords() {
        // "Janssen" mag niet matchen in "Janssens" (ander bedrijf).
        let (match, _) = Matcher(excluded: []).match(app: "Mail", title: "Re: vraag van Janssens", host: "")
        XCTAssertFalse(match.isAssigned)
    }

    func testGenericMailDomainIsIgnored() {
        Store.replaceCompanies([Company(id: "c-x", name: "Klant Met Gmail", domains: ["gmail.com"])])
        let (match, _) = Matcher(excluded: []).match(app: "Safari", title: "Inbox", host: "mail.gmail.com")
        XCTAssertFalse(match.isAssigned)
    }

    func testCorrectionRuleWins() {
        Store.save(Rule(field: "any", pattern: "janssen.be", companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let (match, reason) = Matcher(excluded: []).match(app: "Safari", title: "", host: "janssen.be")
        XCTAssertEqual(match.companyId, "c-peeters")
        XCTAssertTrue(reason.hasPrefix("regel"))
    }

    func testSkipRuleRemovesTime() {
        Store.save(Rule(field: "any", pattern: "youtube.com", skip: true))
        activity(t(9), t(10), host: "youtube.com")
        let p = plan()
        XCTAssertTrue(p.proposals.isEmpty)
    }

    func testDismissedProposalStaysAway() {
        activity(t(13), t(15), host: "janssen.be")
        Store.dismiss(start: t(13), end: t(15))
        XCTAssertTrue(plan().proposals.isEmpty)
    }

    func testUnrecognisedWorkIsStillProposed() {
        activity(t(9), t(10), app: "Figma", title: "Homepage v2")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertFalse(p.proposals[0].match.isAssigned)
        XCTAssertEqual(p.proposals[0].learnPattern, "Figma")
    }

    func testTooShortWorkIsNotProposed() {
        activity(t(9), t(9, 3), host: "janssen.be")
        XCTAssertTrue(plan().proposals.isEmpty)
    }

    func testRoundingNeverOverlapsRegisteredTime() {
        activity(t(13), t(13, 52), host: "janssen.be")
        let registered = Registered(id: "r1", start: t(14), duration: 3600, companyId: nil, companyName: "x", description: "")
        let p = plan(registered: [registered], roundTo: 15)
        XCTAssertEqual(p.proposals.first?.start, t(13))
        XCTAssertLessThanOrEqual(p.proposals.first?.end ?? 0, t(14))
    }

    // MARK: Bevindingen uit de controles

    func testRegistrationWithoutStartTimeIsSubtracted() {
        activity(t(13), t(15), host: "janssen.be")
        let untimed = Registered(id: "r1", start: nil, duration: 3600, companyId: "c-janssen",
                                 companyName: "Janssen NV", description: "", day: "2026-10-27")
        let p = plan(registered: [untimed])
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.duration ?? 0, 3600, accuracy: 1)
    }

    func testMeetingWithClientCountsAsWorkWithoutInput() {
        activity(t(9), t(10), app: "Finder")          // Mac was in gebruik die ochtend
        let meeting = CalendarEvent(start: t(10), end: t(11), title: "Overleg", attendeeEmails: ["piet@janssen.be"])
        let p = plan(events: [meeting])
        let janssen = p.proposals.first { $0.match.companyId == "c-janssen" }
        XCTAssertEqual(janssen?.start, t(10))
        XCTAssertEqual(janssen?.end, t(11))
        XCTAssertTrue(janssen?.reasons.first?.contains("afspraak met piet@janssen.be") ?? false)
    }

    func testRecurringMeetingOnDayOffIsNotWork() {
        let meeting = CalendarEvent(start: t(10), end: t(11), title: "Overleg", attendeeEmails: ["piet@janssen.be"])
        XCTAssertTrue(plan(events: [meeting]).proposals.isEmpty)
    }

    func testUnrecognisedMeetingDoesNotOverrideClientWork() {
        activity(t(10), t(11), host: "janssen.be")
        let webinar = CalendarEvent(start: t(10), end: t(11), title: "Bedrijfswebinar", attendeeEmails: ["x@onbekend.be"])
        let p = plan(events: [webinar])
        XCTAssertEqual(p.proposals.map(\.match.companyId), ["c-janssen"])
    }

    func testPrivateMinutesAreNotBridged() {
        Store.save(Rule(field: "any", pattern: "youtube.com", skip: true))
        activity(t(13), t(14), host: "janssen.be")
        activity(t(14), t(14, 3), host: "youtube.com")
        activity(t(14, 3), t(15), host: "janssen.be")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 2)
        XCTAssertEqual(p.worked, 117 * 60, accuracy: 1)
    }

    func testProposalIdIsStableWhileBlockGrows() {
        activity(t(13), t(14), host: "janssen.be")
        let first = plan().proposals.first?.id
        activity(t(14), t(14, 20), host: "janssen.be")
        XCTAssertEqual(plan().proposals.first?.id, first)
    }

    func testDomainSharedByTwoCompaniesIsIgnored() {
        Store.replaceCompanies([janssen, peeters, Company(id: "c-3", name: "Derde", domains: ["janssen.be"])])
        let (match, _) = Matcher(excluded: []).match(app: "Safari", title: "", host: "janssen.be")
        XCTAssertFalse(match.isAssigned)
    }

    func testOwnCompanyIsNeverAClient() {
        Store.replaceCompanies([janssen, Company(id: "c-mtea", name: "MTEA BV", domains: ["mtea.be"])])
        let (match, _) = Matcher(ownDomain: "mtea.be", excluded: []).match(app: "Mail", title: "Inbox – MTEA", host: "")
        XCTAssertFalse(match.isAssigned)
    }

    func testExcludedSupplierIsNotRecognised() {
        let (match, _) = Matcher(excluded: ["c-janssen"]).match(app: "Safari", title: "", host: "janssen.be")
        XCTAssertFalse(match.isAssigned)
    }

    func testGenericToolsAreNeverLearnedOrMatched() {
        XCTAssertTrue(Matcher.isGeneric("docs.google.com"))
        XCTAssertTrue(Matcher.isGeneric("www.canva.com"))
        XCTAssertFalse(Matcher.isGeneric("janssen.be"))
        XCTAssertFalse(Matcher.isGeneric("klant.co.uk"))
    }

    func testDefaultInvoiceableComesFromTeamleaderPreference() {
        let (match, _) = Matcher(excluded: [], defaultInvoiceable: false).match(app: "Safari", title: "", host: "janssen.be")
        XCTAssertFalse(match.invoiceable)
    }

    // MARK: Bundelen per klant

    func testBundleAddsUpBlocksOfTheSameClient() {
        activity(t(6, 15), t(6, 30), host: "janssen.be")
        activity(t(6, 30), t(9), app: "Figma", title: "Ontwerp")
        activity(t(9), t(9, 15), host: "janssen.be")
        let p = plan(bundle: true)
        let janssen = p.proposals.filter { $0.match.companyId == "c-janssen" }
        XCTAssertEqual(janssen.count, 1)
        XCTAssertEqual(janssen[0].seconds, 30 * 60, accuracy: 1)
        XCTAssertEqual(janssen[0].parts.count, 2)
        XCTAssertEqual(janssen[0].start, t(6, 15))
    }

    func testBundleCountsShortSwitchesThatWouldOtherwiseBeLost() {
        // Drie keer 4 minuten voor Janssen tussen ander werk: los te kort, samen 12 minuten.
        for h in [9, 11, 14] {
            activity(t(h), t(h, 4), host: "janssen.be")
            activity(t(h, 4), t(h, 40), app: "Figma", title: "Ontwerp")
        }
        XCTAssertTrue(plan().proposals.allSatisfy { $0.match.companyId != "c-janssen" })
        let bundled = plan(bundle: true).proposals.first { $0.match.companyId == "c-janssen" }
        XCTAssertEqual(bundled?.seconds ?? 0, 12 * 60, accuracy: 1)
    }

    func testBundleRoundsTheDayTotal() {
        activity(t(9), t(9, 8), host: "janssen.be")
        activity(t(9, 8), t(10), app: "Figma", title: "Ontwerp")
        activity(t(10), t(10, 9), host: "janssen.be")
        let bundled = plan(roundTo: 15, bundle: true).proposals.first { $0.match.companyId == "c-janssen" }
        XCTAssertEqual(bundled?.seconds ?? 0, 15 * 60, accuracy: 1)   // 17 min → 15 min
    }

    func testRegisteredBundleCoversTheRealBlocksNotTheSpan() {
        activity(t(9), t(9, 30), host: "janssen.be")
        activity(t(9, 30), t(10, 30), host: "bakkerijpeeters.be")
        activity(t(10, 30), t(11), host: "janssen.be")
        // TimeTrack registreerde Janssen gebundeld: 1 uur vanaf 9:00 (in Teamleader 9:00–10:00).
        Store.savePushed(teamleaderId: "tl-1", parts: [.init(start: t(9), end: t(9, 30)), .init(start: t(10, 30), end: t(11))])
        let registered = Registered(id: "tl-1", start: t(9), duration: 3600, companyId: "c-janssen",
                                    companyName: "Janssen NV", description: "")
        let p = plan(registered: [registered], bundle: true)
        XCTAssertEqual(p.proposals.map(\.match.companyId), ["c-peeters"])
        XCTAssertEqual(p.proposals.first?.seconds ?? 0, 3600, accuracy: 1)
    }

    // MARK: AI-assistenten

    func testChatTitleIsReadable() {
        XCTAssertEqual(Planner.chatTitle("Offerte Janssen - Claude", app: "Google Chrome"), "Offerte Janssen")
        XCTAssertEqual(Planner.chatTitle("Claude", app: "Claude"), "")
    }

    func testChatMentioningClientIsRecognised() {
        activity(t(9), t(9, 30), app: "Claude", title: "Offerte Bakkerij Peeters herschrijven")
        XCTAssertEqual(plan().proposals.first?.match.companyId, "c-peeters")
    }

    func testUnrecognisedChatGetsClientOfSurroundingWork() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(10, 25), app: "Claude", title: "Tekst herschrijven")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1, "\(p.proposals.map { "\($0.start)-\($0.end) \($0.match.companyName)" })")
        XCTAssertEqual(p.proposals.first?.end, t(10, 25))
        XCTAssertTrue(p.proposals.first?.reasons.contains { $0.contains("na werk voor Janssen NV") } ?? false,
                      "\(p.proposals.first?.reasons ?? [])")
    }

    func testChatFarFromOtherWorkStaysUnrecognisedAndLearnsTheChatTitle() {
        activity(t(9), t(9, 20), host: "janssen.be")
        activity(t(11), t(11, 25), title: "Nieuwsbrief november - Claude", host: "claude.ai")
        let chat = plan().proposals.first { $0.start == t(11) }
        XCTAssertFalse(chat?.match.isAssigned ?? true)
        XCTAssertEqual(chat?.learnPattern, "Nieuwsbrief november")
    }

    // MARK: Oproepen en meetings

    /// Teksten zoals Flow ze toont (volgorde van het scherm): contactkaart links, gesprekspaneel rechts.
    private let flowActive = ["Beschikbaar tot 17:30", "Overzicht", "Matthias Rijnwalt", "Beschikbaar", "Contactgegevens",
                              "Telefoonnummer", "056 90 89 41", "Bedrijfsnaam", "M&M", "Oproepgeschiedenis",
                              "Uitgaande oproep", "07:17", "00:22", "M.", "Matthias .", "M&M", "0493 29 50 63",
                              "Via", "Mtea - Verkoop", "Gewenst 003256446650", "Ophangen", "Parkeren", "Doorverbinden"]
    private let flowRinging = ["Beschikbaar tot 17:30", "Telefoonnummer", "056 90 89 41", "07:17", "Inkomende oproep",
                               "M.", "Matthias .", "M&M", "0493 29 50 63", "Via", "Mtea - Verkoop",
                               "Gewenst 003256446650", "Verwijderen", "Antwoorden"]

    func testFlowActiveCallIsRead() {
        let call = FlowReader.parse(flowActive)
        XCTAssertEqual(call?.number, "0493 29 50 63")
        XCTAssertEqual(call?.key, "tel:493295063")
        XCTAssertEqual(call?.detail, "Matthias · M&M")
        XCTAssertEqual(call?.ringing, false)
    }

    func testFlowIncomingCallIsRead() {
        let call = FlowReader.parse(flowRinging)
        XCTAssertEqual(call?.number, "0493 29 50 63")
        XCTAssertEqual(call?.ringing, true)
    }

    func testFlowWithoutCallIsNothing() {
        XCTAssertNil(FlowReader.parse(["Beschikbaar tot 17:30", "Telefoonnummer", "056 90 89 41", "07:17"]))
    }

    func testPhoneNumbersCompareRegardlessOfNotation() {
        XCTAssertEqual(Phone.key("0493 29 50 63"), Phone.key("+32 493 29 50 63"))
        XCTAssertEqual(Phone.key("0032493295063"), "493295063")
        XCTAssertTrue(Phone.looksLikeNumber("+32 56 11 09 59"))
        XCTAssertFalse(Phone.looksLikeNumber("00:22"))
        XCTAssertFalse(Phone.looksLikeNumber("Gewenst 003256446650"))
    }

    func testCompanyPhoneNumberIsRecognised() {
        Store.replaceCompanies([Company(id: "c-janssen", name: "Janssen NV", domains: ["janssen.be"], phones: ["493295063"])])
        let hit = Matcher(excluded: []).match(phone: "+32 493 29 50 63")
        XCTAssertEqual(hit?.0.companyId, "c-janssen")
    }

    func testCallCountsAsWorkForTheChosenClient() {
        activity(t(10), t(10, 25), app: "Flow", title: "Flow")
        let call = CallRecord(start: t(10), end: t(10, 25), kind: .phone, label: "0493 29 50 63", detail: "Matthias · M&M",
                              companyId: "c-peeters", companyName: "Bakkerij Peeters BV", confirmed: true)
        let p = plan(calls: [call])
        let peeters = p.proposals.first { $0.match.companyId == "c-peeters" }
        XCTAssertEqual(peeters?.duration ?? 0, 25 * 60, accuracy: 61)
        XCTAssertTrue(peeters?.reasons.first?.contains("telefoon met Matthias · M&M") ?? false, "\(peeters?.reasons ?? [])")
    }

    func testCallMarkedNoClientIsNotProposed() {
        let call = CallRecord(start: t(10), end: t(10, 25), kind: .phone, label: "0493", skip: true)
        XCTAssertTrue(plan(calls: [call]).proposals.isEmpty)
    }

    func testCallMemoryRemembersTheAnswer() {
        Store.remember("tel:493295063", Match(companyId: "c-janssen", companyName: "Janssen NV"))
        XCTAssertEqual(Store.callMemory("tel:493295063")?.companyId, "c-janssen")
        Store.remember("tel:111111111", Match(skip: true))
        XCTAssertEqual(Store.callMemory("tel:111111111")?.skip, true)
    }

    func testKnownCompanyPhoneIsDetectedAndCanBeAdded() {
        XCTAssertFalse(Store.companyHasPhone("493295063"))
        Store.addCompanyPhone(companyId: "c-janssen", key: "493295063")
        XCTAssertTrue(Store.companyHasPhone("493295063"))
        XCTAssertFalse(Store.companyHasPhone("93295063"))   // geen gedeeltelijke treffer
        XCTAssertEqual(Matcher(excluded: []).match(phone: "0493 29 50 63")?.0.companyId, "c-janssen")
    }

    // MARK: Blokken zelf toewijzen, venstertitels

    func testAssignedBlockMovesToOtherClientsBundle() {
        activity(t(9), t(9, 30), host: "janssen.be")
        activity(t(10), t(10, 30), host: "janssen.be")
        Store.assign(start: t(10), end: t(10, 30), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let p = plan(bundle: true)
        let janssen = p.proposals.first { $0.match.companyId == "c-janssen" }
        let peeters = p.proposals.first { $0.match.companyId == "c-peeters" }
        XCTAssertEqual(janssen?.seconds ?? 0, 30 * 60, accuracy: 1)
        XCTAssertEqual(peeters?.seconds ?? 0, 30 * 60, accuracy: 1)
        XCTAssertTrue(peeters?.reasons.first?.contains("door jou toegewezen") ?? false)
    }

    func testShortAssignedBlockIsNotSmoothedAway() {
        activity(t(9), t(10), host: "janssen.be")
        Store.assign(start: t(9, 20), end: t(9, 24), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let p = plan(bundle: true)
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-peeters" }?.seconds ?? 0, 0, accuracy: 1,
                       "korter dan 5 min telt (nog) niet als voorstel")
        // Maar de minuten mogen ook niet terug naar Janssen gaan.
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-janssen" }?.seconds ?? 0, 56 * 60, accuracy: 1)
    }

    func testBrowserProfileNameIsNotAClient() {
        Store.replaceCompanies([janssen, Company(id: "c-matthias", name: "Matthias", domains: [])])
        XCTAssertEqual(Matcher.cleanTitle("TPC Cloud - Google Chrome - Matthias"), "TPC Cloud")
        let (match, _) = Matcher(excluded: [], ownNames: []).match(app: "Google Chrome", title: "TPC Cloud - Google Chrome - Matthias", host: "")
        XCTAssertFalse(match.isAssigned)
    }

    func testOwnNameIsNeverAClient() {
        Store.replaceCompanies([Company(id: "c-matthias", name: "Matthias Rijnwalt", domains: [])])
        let (match, _) = Matcher(excluded: [], ownNames: ["Matthias Rijnwalt"]).match(app: "Mail", title: "Offerte voor Matthias Rijnwalt", host: "")
        XCTAssertFalse(match.isAssigned)
    }

    // MARK: Bevindingen onafhankelijke controle

    func testBundlingKeepsShortBlockBetweenOtherClient() {
        activity(t(9), t(9, 20), host: "janssen.be")
        activity(t(9, 20), t(9, 24), host: "bakkerijpeeters.be")
        activity(t(9, 24), t(9, 44), host: "janssen.be")
        let p = plan(bundle: true)
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-janssen" }?.seconds ?? 0, 40 * 60, accuracy: 1)
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-peeters" }?.seconds ?? 0, 0, accuracy: 1,
                       "4 min alleen is nog geen voorstel, maar mag ook niet bij Janssen")
    }

    func testAlternatingShortBlocksKeepTheirClient() {
        for i in 0..<6 {
            activity(t(9, i * 8), t(9, i * 8 + 4), host: "janssen.be")
            activity(t(9, i * 8 + 4), t(9, i * 8 + 8), host: "bakkerijpeeters.be")
        }
        let p = plan(bundle: true)
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-janssen" }?.seconds ?? 0, 24 * 60, accuracy: 1)
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-peeters" }?.seconds ?? 0, 24 * 60, accuracy: 1)
    }

    func testTitleCleaningOnlyAtTheEnd() {
        XCTAssertEqual(Matcher.cleanTitle("Offerte - Architectenbureau Janssen"), "Offerte - Architectenbureau Janssen")
        XCTAssertEqual(Matcher.cleanTitle("Offerte - Architectenbureau Janssen - Google Chrome"), "Offerte - Architectenbureau Janssen")
        XCTAssertEqual(Matcher.cleanTitle("Inbox - Arc"), "Inbox")
    }

    func testFlowHistoryWordsAreNotACall() {
        // "Inkomende oproep" in de oproepgeschiedenis, zonder de knoppen van het gesprekspaneel.
        XCTAssertNil(FlowReader.parse(["Oproepgeschiedenis", "Inkomende oproep", "0493 29 50 63", "Verwijderen", "07:17"]))
    }

    func testVideoBetweenClientWorkGetsThatClient() {
        activity(t(9), t(10), host: "janssen.be")
        activity(t(10), t(10, 25), title: "Hoe werkt X - YouTube", host: "youtube.com")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.end, t(10, 25))
    }

    func testPruneRemovesOnlyOldActivity() {
        let old = Date().timeIntervalSince1970 - 100 * 86400
        activity(old, old + 600, host: "janssen.be")
        activity(t(9), t(9, 10), host: "janssen.be")
        Store.pruneOldActivity()
        XCTAssertEqual(Database.shared.query("SELECT COUNT(*) AS n FROM activity").first?.int("n"), 1)
    }

    // MARK: Opdelen van niet-herkend werk

    func testUnrecognisedWorkIsSplitPerActivity() {
        activity(t(7, 13), t(7, 47), app: "Claude", title: "Claude-chat 4f2a91c3")
        activity(t(7, 47), t(8, 7), host: "klaviyo.com")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 2, "\(p.proposals.map { "\($0.start)-\($0.end)" })")
        XCTAssertEqual(p.proposals.first?.learnPattern, "Claude-chat 4f2a91c3")
        XCTAssertEqual(p.proposals.last?.learnPattern, "klaviyo.com")
    }

    func testTinyUnrecognisedPiecesStayWithTheirNeighbour() {
        activity(t(9), t(9, 30), app: "Figma", title: "Ontwerp")
        activity(t(9, 30), t(9, 32), host: "klaviyo.com")
        activity(t(9, 32), t(10), app: "Figma", title: "Ontwerp")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.duration ?? 0, 3600, accuracy: 1)
    }

    func testEveryMailInsideABlockIsItsOwnPiece() {
        // Twee mails in hetzelfde programma: apart toe te wijzen, ook al is het telkens "Mail".
        activity(t(10, 58), t(11, 1), app: "Mail", title: "Re: Bouw Wannegem")
        activity(t(11, 1), t(11, 5), app: "Mail", title: "Re: Recht van opstal")
        activity(t(11, 5), t(11, 9), app: "Claude", title: "Claude")
        let p = plan()
        let labels = p.proposals.flatMap { $0.pieces.map(\.label) }
        XCTAssertTrue(labels.contains("Mail: Re: Bouw Wannegem"), "\(labels)")
        XCTAssertTrue(labels.contains("Mail: Re: Recht van opstal"), "\(labels)")
        guard let mail = p.proposals.flatMap(\.pieces).first(where: { $0.label == "Mail: Re: Recht van opstal" })
        else { return XCTFail("geen deel voor de mail") }
        XCTAssertEqual(mail.start, t(11, 1))
        XCTAssertEqual(mail.end, t(11, 5))
    }

    func testShortCompanyNameWithAmpersandIsRecognisedInAMailSubject() {
        Store.replaceCompanies([janssen, Company(id: "c-mm", name: "M&M bv", domains: [])])
        let (m, _) = Matcher(ownDomain: "mtea.be", excluded: [], ownNames: [])
            .match(app: "Mail", title: "Re: Recht van opstal M&M bv", host: "")
        XCTAssertEqual(m.companyId, "c-mm")
        // Losse letters blijven geen klant.
        let (n, _) = Matcher(ownDomain: "mtea.be", excluded: [], ownNames: [])
            .match(app: "Mail", title: "Re: m en m", host: "")
        XCTAssertFalse(n.isAssigned)
    }

    func testOnlyASpecificSubjectIsOfferedToRemember() {
        XCTAssertEqual(ActivityAssignView.learnPattern("Mail: Re: Recht van opstal M&M bv"), "recht van opstal m&m bv")
        XCTAssertEqual(ActivityAssignView.learnPattern("Mail: FW: Re: Offerte dakwerken"), "offerte dakwerken")
        XCTAssertNil(ActivityAssignView.learnPattern("Mail: Alle inkomende – 144.066 berichten, 12.341 ongelezen"))
        XCTAssertNil(ActivityAssignView.learnPattern("Google Chrome: gmail.com"))
        XCTAssertNil(ActivityAssignView.learnPattern("Claude"))
    }

    func testEveryProposalGetsAShortDescriptionForTheClient() {
        activity(t(10, 58), t(11, 5), app: "Mail", title: "Re: Recht van opstal")
        activity(t(11, 5), t(11, 9), app: "Mail", title: "Alle inkomende – 144.066 berichten, 12.341 ongelezen")
        activity(t(13), t(14), host: "janssen.be")
        let p = plan()
        XCTAssertFalse(p.proposals.isEmpty)
        for proposal in p.proposals {
            XCTAssertFalse(proposal.description.trimmingCharacters(in: .whitespaces).isEmpty, "geen omschrijving: \(proposal)")
        }
        XCTAssertTrue(p.proposals.contains { $0.description.hasPrefix("Mailverkeer ‘Recht van opstal’") },
                      p.proposals.map(\.description).description)
        XCTAssertTrue(p.proposals.contains { $0.description == "Werk aan janssen.be" }, p.proposals.map(\.description).description)
    }

    func testDescriptionsReadWellForTheClient() {
        XCTAssertEqual(Describer.describe(activities: ["Telefoon: 0493 29 50 63"]), "Telefoongesprek")
        XCTAssertEqual(Describer.describe(activities: ["Telefoon: Piet Janssen"]), "Telefoongesprek met Piet Janssen")
        XCTAssertEqual(Describer.describe(activities: ["Microsoft Word: Offerte dakwerken.docx", "Mail: FW: Re: Planning"]),
                       "Document ‘Offerte dakwerken’ en mailverkeer ‘Planning’")
        XCTAssertEqual(Describer.describe(activities: ["Claude: Claude"]), "Uitwerking en analyse")
        XCTAssertEqual(Describer.describe(activities: ["claude.ai: Nieuwsbrief november"]), "Uitwerking ‘Nieuwsbrief november’")
        XCTAssertEqual(Describer.describe(activities: ["Google Chrome: youtube.com"]), "Opzoekwerk")
        XCTAssertEqual(Describer.describe(activities: []), "Werk voor de klant")
    }

    func testTeamleaderGetsEveryRegistrationRoundedUpToTenMinutes() {
        UserDefaults.standard.removeObject(forKey: "billRoundTo")
        XCTAssertEqual(Prefs.billed(180), 600, "3 min bellen = 10 min")
        XCTAssertEqual(Prefs.billed(30), 600)
        XCTAssertEqual(Prefs.billed(600), 600, "precies 10 min blijft 10 min")
        XCTAssertEqual(Prefs.billed(660), 1200, "11 min = 20 min")
        XCTAssertEqual(Prefs.billed(3540), 3600)
        UserDefaults.standard.set(15, forKey: "billRoundTo")
        defer { UserDefaults.standard.removeObject(forKey: "billRoundTo") }
        XCTAssertEqual(Prefs.billed(180), 900)
    }

    func testWipingADayRemovesOnlyThatDaysTracking() {
        activity(t(10), t(12), host: "janssen.be")
        let nextDay = t(10) + 86400
        activity(nextDay, nextDay + 3600, host: "janssen.be")
        // Loopt over middernacht de dag in: enkel het deel van die dag verdwijnt.
        activity(t(0) - 600, t(0) + 600, host: "janssen.be")
        Store.assign(start: t(10), end: t(11), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        Store.dismiss(start: t(11), end: t(11, 30))
        let (lo, hi) = Store.dayBounds(day)
        Store.wipeDay(from: lo, to: hi)
        XCTAssertEqual(plan().worked, 0, "na wissen nog activiteit op deze dag")
        XCTAssertTrue(plan().proposals.isEmpty)
        XCTAssertTrue(Store.assignments(from: lo, to: hi).isEmpty)
        XCTAssertTrue(Store.dismissed(from: lo, to: hi).isEmpty)
        let rows = Database.shared.query("SELECT start, end FROM activity ORDER BY start")
        XCTAssertEqual(rows.count, 2, "de andere dagen blijven staan")
        XCTAssertEqual(rows.first?.double("end") ?? 0, lo, accuracy: 0.5, "het deel vóór middernacht blijft")
    }

    func testClaudeConversationTitleIsTakenFromTheHeaderNotTheSidebar() {
        typealias T = AIChatReader.Text
        let texts = [
            T(text: "Claude", role: "AXStaticText", frame: CGRect(x: 0, y: 30, width: 80, height: 20)),
            T(text: "New chat", role: "AXButton", frame: CGRect(x: 10, y: 60, width: 120, height: 24)),
            T(text: "Offerte dakwerken Peeters", role: "AXLink", frame: CGRect(x: 10, y: 120, width: 200, height: 20)),
            T(text: "Nieuwsbrief november Janssen", role: "AXButton", frame: CGRect(x: 420, y: 34, width: 260, height: 24)),
            T(text: "Share", role: "AXButton", frame: CGRect(x: 1200, y: 34, width: 60, height: 24)),
            T(text: "Schrijf een nieuwsbrief over…", role: "AXStaticText", frame: CGRect(x: 420, y: 200, width: 600, height: 40)),
        ]
        XCTAssertEqual(AIChatReader.headerTitle(texts), "Nieuwsbrief november Janssen")
        XCTAssertNil(AIChatReader.headerTitle(Array(texts.prefix(3)) + [texts[4]]), "enkel vaste knoppen: geen titel")
    }

    func testAChatTitleWithTheClientNameGoesToThatClient() {
        activity(t(9), t(9, 30), app: "Claude", title: "Nieuwsbrief november — Janssen NV")
        let p = plan()
        XCTAssertEqual(p.proposals.first?.match.companyId, "c-janssen", "\(p.proposals.map(\.match.companyName))")
    }

    func testClaudeChatProjectAndCodeGetTheirOwnStableName() {
        XCTAssertEqual(Tracker.chatName(URL(string: "https://claude.ai/chat/4f2a91c3-1234-5678")!), "Claude-chat 4f2a91c3")
        XCTAssertEqual(Tracker.chatName(URL(string: "https://claude.ai/project/0198aa11-2233")!), "Claude-project 0198aa11")
        XCTAssertEqual(Tracker.chatName(URL(string: "https://claude.ai/code/session_01PHQa8y")!), "Claude Code-sessie session_")
        XCTAssertNil(Tracker.chatName(URL(string: "file:///Applications/Claude.app/Contents/Resources/app.asar/")!))
        XCTAssertEqual(Planner.chatTitle("Nieuwsbrief november - Claude", app: "Claude"), "Nieuwsbrief november")
        XCTAssertEqual(Planner.chatTitle("Refactor planner - Claude Code", app: "Claude"), "Refactor planner")
        XCTAssertEqual(Planner.chatTitle("Claude Code", app: "Claude"), "")
    }

    func testPiecesShowWhatHappenedInsideABlock() {
        activity(t(9), t(9, 20), host: "janssen.be")
        activity(t(9, 20), t(9, 40), app: "Microsoft Word", title: "Offerte Janssen.docx")
        let p = plan()
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.pieces.count, 2)
        XCTAssertEqual(p.proposals.first?.pieces.last?.start, t(9, 20))
    }

    func testAssigningAPieceMovesOnlyThatPiece() {
        activity(t(9), t(9, 20), host: "janssen.be")
        activity(t(9, 20), t(9, 40), app: "Microsoft Word", title: "Offerte Janssen.docx")
        Store.assign(start: t(9, 20), end: t(9, 40), to: Match(companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let p = plan()
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-janssen" }?.duration ?? 0, 20 * 60, accuracy: 1)
        XCTAssertEqual(p.proposals.first { $0.match.companyId == "c-peeters" }?.duration ?? 0, 20 * 60, accuracy: 1)
    }

    // MARK: Gesprekken na elkaar

    func testRoundingDoesNotExtendTheRealBlock() {
        activity(t(10), t(10, 4), app: "Flow", title: "Flow")
        let call = CallRecord(start: t(10), end: t(10, 4), kind: .phone, label: "0493 29 50 63",
                              companyId: "c-janssen", companyName: "Janssen NV", confirmed: true)
        let p = plan(roundTo: 5, calls: [call])
        XCTAssertEqual(p.proposals.first?.seconds ?? 0, 4 * 60, accuracy: 1, "een gesprek: de echte duur")
        XCTAssertEqual(p.proposals.first?.parts.last?.end, t(10, 4), "het blok zelf blijft 10:00–10:04")
    }

    func testSecondCallAfterRegisteringTheFirstIsProposedAgain() {
        let first = CallRecord(start: t(10), end: t(10, 4), kind: .phone, label: "0493 29 50 63",
                               companyId: "c-janssen", companyName: "Janssen NV", confirmed: true)
        let second = CallRecord(start: t(10, 5), end: t(10, 11), kind: .phone, label: "0493 29 50 63",
                                companyId: "c-janssen", companyName: "Janssen NV", confirmed: true)
        activity(t(10), t(10, 11), app: "Flow", title: "Flow")
        // Het eerste gesprek werd geregistreerd (afgerond op 5 min, dus tot 10:05 in Teamleader).
        Store.savePushed(teamleaderId: "tl-call", parts: [.init(start: t(10), end: t(10, 4))])
        let registered = Registered(id: "tl-call", start: t(10), duration: 300, companyId: "c-janssen",
                                    companyName: "Janssen NV", description: "")
        let p = plan(registered: [registered], roundTo: 5, calls: [first, second])
        XCTAssertEqual(p.proposals.count, 1)
        XCTAssertEqual(p.proposals.first?.start, t(10, 5))
        XCTAssertEqual(p.proposals.first?.seconds ?? 0, 6 * 60, accuracy: 1)
    }

    func testTimeInThePhoneAppOutsideACallIsNotWork() {
        activity(t(10), t(10, 20), app: "Flow", title: "Flow")
        XCTAssertTrue(plan().proposals.isEmpty)
        XCTAssertEqual(plan().worked, 0, accuracy: 1)
    }

    func testEachCallIsItsOwnRegistrationWithItsRealTime() {
        activity(t(9), t(10), host: "janssen.be")
        let call = CallRecord(start: t(10, 0) + 20, end: t(10, 3) + 40, kind: .phone, label: "0493 29 50 63",
                              companyId: "c-janssen", companyName: "Janssen NV", confirmed: true)
        activity(t(10, 4), t(11), host: "janssen.be")
        let p = plan(roundTo: 15, bundle: true, calls: [call])
        let janssen = p.proposals.filter { $0.match.companyId == "c-janssen" }
        XCTAssertEqual(janssen.count, 2, "gesprek apart van het andere werk voor Janssen")
        let phone = janssen.first { $0.reasons.first?.contains("telefoon") ?? false }
        XCTAssertEqual(phone?.start, t(10, 0) + 20)
        XCTAssertEqual(phone?.seconds ?? 0, 4 * 60, accuracy: 1, "3 min 20 s → 4 min, niet 15")
    }
}
