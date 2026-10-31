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

    private func plan(registered: [Registered] = [], roundTo: Int = 1) -> DayPlan {
        Planner.plan(day: day, registered: registered, matcher: Matcher(), roundTo: roundTo)
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
        let (match, reason) = Matcher().match(app: "Microsoft Word", title: "Offerte Bakkerij Peeters v3.docx", host: "")
        XCTAssertEqual(match.companyId, "c-peeters")
        XCTAssertTrue(reason.contains("Bakkerij Peeters"))
    }

    func testNameMustMatchWholeWords() {
        // "Janssen" mag niet matchen in "Janssens" (ander bedrijf).
        let (match, _) = Matcher().match(app: "Mail", title: "Re: vraag van Janssens", host: "")
        XCTAssertFalse(match.isAssigned)
    }

    func testGenericMailDomainIsIgnored() {
        Store.replaceCompanies([Company(id: "c-x", name: "Klant Met Gmail", domains: ["gmail.com"])])
        let (match, _) = Matcher().match(app: "Safari", title: "Inbox", host: "mail.gmail.com")
        XCTAssertFalse(match.isAssigned)
    }

    func testCorrectionRuleWins() {
        Store.save(Rule(field: "any", pattern: "janssen.be", companyId: "c-peeters", companyName: "Bakkerij Peeters BV"))
        let (match, reason) = Matcher().match(app: "Safari", title: "", host: "janssen.be")
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
}
