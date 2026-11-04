import Foundation

/// Een tijdsregistratie die al in Teamleader staat.
struct Registered: Identifiable, Hashable {
    let id: String
    let start: Double?          // nil bij een registratie op duur, zonder tijdstip
    let duration: Double
    let companyId: String?
    let companyName: String
    let description: String
    var day: String? = nil      // yyyy-MM-dd (voor registraties zonder tijdstip)

    var end: Double? { start.map { $0 + duration } }
}

/// Voorstel voor een periode waarin gewerkt is maar die nog niet in Teamleader staat.
struct Proposal: Identifiable, Hashable {
    struct Part: Hashable {
        var start: Double
        var end: Double
    }

    var start: Double           // begin van het eerste blok (wordt het starttijdstip in Teamleader)
    var end: Double             // einde van het laatste blok
    var match: Match
    var reasons: [String]       // waarom deze klant, bv. "website janssen.be · 1u10"
    var activities: [String]    // wat je deed
    var description: String
    var learnPattern: String    // kandidaat voor een correctieregel (domein, programma of chattitel)
    /// De echte werkblokken. Bij "bundelen per klant" zijn dat er meerdere verspreid over de dag.
    var parts: [Part]
    /// Te registreren duur (som van de blokken, afgerond; aanpasbaar op de kaart).
    var seconds: Double
    var bundled = false

    /// Blijft gelijk terwijl het lopende blok langer wordt, zodat bewerkingen op een kaart niet verloren gaan.
    var id: String { bundled ? "dag|\(match.key)" : "\(Int(start))|\(match.key)" }
    var duration: Double { seconds }

    /// Haalt tijd weg van het einde van het laatste blok (voor registraties zonder tijdstip).
    mutating func shorten(by amount: Double) {
        var remaining = amount
        while remaining > 0, let last = parts.last {
            let take = min(remaining, last.end - last.start)
            parts[parts.count - 1].end -= take
            remaining -= take
            if parts[parts.count - 1].end - parts[parts.count - 1].start < 1 { parts.removeLast() }
        }
        seconds = max(0, seconds - amount)
        end = parts.last?.end ?? start
    }
}

/// Activiteit op de tijdlijn, gekleurd per klant.
struct TimelineBlock: Identifiable {
    let id: Int
    let start: Double
    var end: Double
    let label: String
    let kind: Kind

    enum Kind { case assigned, unassigned, skipped }
}

struct DayPlan {
    var worked: Double = 0
    var proposals: [Proposal] = []
    var registered: [Registered] = []
    var activity: [TimelineBlock] = []

    var registeredSeconds: Double { registered.reduce(0) { $0 + $1.duration } }
    var proposedSeconds: Double { proposals.reduce(0) { $0 + $1.duration } }
}

/// Bouwt het dagvoorstel per minuut:
/// - een minuut telt als werk bij minstens 20 s activiteit, of tijdens een afspraak (met deelnemers of een klant);
/// - de klant met de meeste seconden in die minuut wint (een afspraak gaat altijd voor);
/// - minuten die al in Teamleader staan of die je negeerde, vallen weg;
/// - korte onderbrekingen worden gladgestreken, en wat overblijft wordt één voorstel per aaneengesloten klantblok.
enum Planner {
    static let minSecondsPerMinute = 20.0
    static let bridgeMinutes = 3
    static let minProposalMinutes = 5
    static let absorbUnassignedMinutes = 10

    private struct Info {
        var seconds = 0.0
        var reasons: [String: Double] = [:]
        var activities: [String: Double] = [:]
        var learn: [String: Double] = [:]
        var descriptions: [String: Double] = [:]
    }

    private struct Run {
        let key: String
        let from: Int
        let to: Int
        var length: Int { to - from }
    }

    static let calendarActivityMargin = 15.0 * 60
    /// Werk in een AI-assistent zonder herkende klant krijgt de klant van het werk ervoor of erna (binnen deze marge).
    static let assistantContextMinutes = 30

    static let assistantApps: Set<String> = ["Claude", "ChatGPT", "Gemini", "Copilot", "Microsoft Copilot",
                                             "Perplexity", "Le Chat", "Cursor"]
    static let assistantHosts: Set<String> = ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
                                              "copilot.microsoft.com", "perplexity.ai", "www.perplexity.ai",
                                              "chat.mistral.ai", "aistudio.google.com"]

    static func isAssistant(app: String, host: String) -> Bool {
        assistantApps.contains(app) || assistantHosts.contains(host)
    }

    /// "Offerte Janssen - Claude" → "Offerte Janssen"; een titel die enkel de naam van de assistent is, telt niet.
    static func chatTitle(_ title: String, app: String) -> String {
        var t = Matcher.cleanTitle(title)
        for suffix in [" - Claude", " – Claude", " | Claude", " - ChatGPT", " | ChatGPT", " - Gemini", " - Perplexity",
                       " - Google Chrome", " — Google Chrome", " - Safari", " - Microsoft Edge"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = ["", app, "Claude", "ChatGPT", "Gemini", "Copilot", "Perplexity", "New chat",
                                    "Nieuwe chat", "New Chat"]
        return generic.contains(t) ? "" : t
    }

    /// - Parameters:
    ///   - events: afspraken (nil = uit de agenda's op deze Mac); voor tests in te vullen.
    ///   - dismissed: genegeerde periodes (nil = uit de database).
    ///   - bundle: per klant één voorstel voor de hele dag (in plaats van één per blok).
    ///   - calls: oproepen en meetings (nil = uit de database).
    ///   - assignments: blokken die de gebruiker zelf aan een klant toewees (nil = uit de database).
    static func plan(day: Date, registered: [Registered], matcher: Matcher = Matcher(), roundTo: Int = 5,
                     events: [CalendarEvent]? = nil, dismissed: [(Double, Double)]? = nil,
                     bundle: Bool = false, calls: [CallRecord]? = nil,
                     assignments: [Store.Assignment]? = nil) -> DayPlan {
        let (lo, hi) = Store.dayBounds(day)
        let n = max(1, Int(((hi - lo) / 60).rounded()))
        var minutes = [[String: Info]](repeating: [:], count: n)
        var forced = [String?](repeating: nil, count: n)
        var skippedSeconds = [Double](repeating: 0, count: n)
        var assistantSeconds = [Double](repeating: 0, count: n)
        var pinned = [Bool](repeating: false, count: n)   // door de gebruiker toegewezen: niet gladstrijken
        var matches: [String: Match] = [:]
        var activity: [TimelineBlock] = []

        func index(_ t: Double) -> Int { min(n - 1, max(0, Int((t - lo) / 60))) }

        // 1. Activiteit op de laptop
        let segments = Store.segments(from: lo, to: hi).filter { !$0.isIdle }
        for seg in segments {
            let (m, reason) = matcher.match(app: seg.app, title: seg.title, host: seg.host)
            let label = m.skip ? "Genegeerd" : (m.isAssigned ? m.companyName : "Niet toegewezen")
            let kind: TimelineBlock.Kind = m.skip ? .skipped : (m.isAssigned ? .assigned : .unassigned)
            if let last = activity.last, last.label == label, seg.start - last.end < 60 {
                activity[activity.count - 1].end = seg.end
            } else {
                activity.append(TimelineBlock(id: activity.count, start: seg.start, end: seg.end, label: label, kind: kind))
            }
            if m.skip {
                var t = seg.start
                while t < seg.end {
                    let i = index(t)
                    let next = min(seg.end, lo + Double(i + 1) * 60)
                    guard next > t else { break }
                    skippedSeconds[i] += next - t
                    t = next
                }
                continue
            }
            matches[m.key] = m
            let assistant = isAssistant(app: seg.app, host: seg.host)
            let chatTitle = Self.chatTitle(seg.title, app: seg.app)
            let what = assistant && !chatTitle.isEmpty
                ? "\(seg.host.isEmpty ? seg.app : seg.host): \(chatTitle)"
                : seg.host.isEmpty ? (seg.title.isEmpty ? seg.app : "\(seg.app): \(seg.title)") : "\(seg.app): \(seg.host)"
            // Bij een AI-chat is de titel van het gesprek de beste kandidaat om te onthouden.
            let learn = assistant && !chatTitle.isEmpty ? chatTitle : (seg.host.isEmpty ? seg.app : seg.host)
            var t = seg.start
            while t < seg.end {
                let i = index(t)
                let next = min(seg.end, lo + Double(i + 1) * 60)
                guard next > t else { break }
                let s = next - t
                var info = minutes[i][m.key] ?? Info()
                info.seconds += s
                info.reasons[reason, default: 0] += s
                info.activities[String(what.prefix(80)), default: 0] += s
                info.learn[learn, default: 0] += s
                minutes[i][m.key] = info
                if assistant && !m.isAssigned { assistantSeconds[i] += s }
                t = next
            }
        }

        // 2. Afspraken in de agenda: werk, ook zonder muis of toetsenbord. Voorwaarden:
        //    - een klant herkend of andere deelnemers (een eigen blok "focus" telt niet),
        //    - de Mac werd rond die tijd gebruikt (geen feestdag of vrije dag met een terugkerende afspraak).
        //    Bij overlap wint een afspraak met herkende klant; een afspraak zonder klant overschrijft
        //    geen herkend werk op de laptop.
        let allEvents = events ?? CalendarSource.shared.events(from: lo, to: hi)
        let matchedEvents = allEvents.compactMap { event -> (CalendarEvent, Match, String)? in
            let hit = matcher.match(event: event)
            guard hit != nil || !event.attendeeEmails.isEmpty else { return nil }
            let m = hit?.0 ?? .unassigned
            guard !m.skip else { return nil }
            let usedMac = segments.contains {
                $0.end > event.start - calendarActivityMargin && $0.start < event.end + calendarActivityMargin
            }
            guard usedMac else { return nil }
            return (event, m, hit?.1 ?? "agenda: \(event.title)")
        }.sorted { a, b in (a.1.isAssigned ? 1 : 0) < (b.1.isAssigned ? 1 : 0) }
        for (event, m, reason) in matchedEvents {
            matches[m.key] = m
            let first = index(event.start)
            let last = min(n, Int(((event.end - lo) / 60).rounded(.up)))
            guard first < last else { continue }
            for i in first..<last {
                if !m.isAssigned {
                    let assignedActivity = minutes[i].filter { !$0.key.isEmpty }.values.reduce(0) { $0 + $1.seconds }
                    if assignedActivity >= 30 { continue }
                }
                forced[i] = m.key
                var info = minutes[i][m.key] ?? Info()
                info.seconds = max(info.seconds, 60)
                info.reasons[reason, default: 0] += 60
                info.activities["Afspraak: \(event.title)", default: 0] += 60
                info.descriptions[event.title, default: 0] += 60
                info.learn[event.title, default: 0] += 60
                minutes[i][m.key] = info
            }
        }

        // 2b. Oproepen (Flow) en meetings: werk voor de klant die je koos of die herkend werd. Ze gaan voor de
        //     agenda; een gesprek zonder klant overschrijft geen herkend werk; "geen klant" telt niet.
        for call in calls ?? Store.calls(from: lo, to: hi) where !call.skip {
            let m = call.match
            matches[m.key] = m
            let reason = call.kind == .phone
                ? "telefoon met \(call.detail.isEmpty ? call.label : call.detail)"
                : "meeting: \(call.label)"
            let first = index(call.start)
            let last = min(n, Int(((call.end - lo) / 60).rounded(.up)))
            guard first < last else { continue }
            for i in first..<last {
                if !m.isAssigned {
                    let assignedActivity = minutes[i].filter { !$0.key.isEmpty }.values.reduce(0) { $0 + $1.seconds }
                    if assignedActivity >= 30 { continue }
                }
                forced[i] = m.key
                var info = minutes[i][m.key] ?? Info()
                info.seconds = max(info.seconds, 60)
                info.reasons[reason, default: 0] += 60
                info.activities[call.kind == .phone ? "Telefoon: \(call.label)" : "Meeting: \(call.label)", default: 0] += 60
                if call.kind == .meeting { info.descriptions[call.label, default: 0] += 60 }
                minutes[i][m.key] = info
            }
        }

        // 2c. Zelf toegewezen blokken gaan voor alles: al het werk in die minuten hoort bij die klant.
        for a in assignments ?? Store.assignments(from: lo, to: hi) {
            let m = a.match
            matches[m.key] = m
            let first = index(a.start)
            let last = min(n, Int(((a.end - lo) / 60).rounded(.up)))
            guard first < last else { continue }
            for i in first..<last {
                var merged = Info()
                for (_, info) in minutes[i] {
                    merged.seconds += info.seconds
                    info.activities.forEach { merged.activities[$0.key, default: 0] += $0.value }
                    info.learn.forEach { merged.learn[$0.key, default: 0] += $0.value }
                    info.descriptions.forEach { merged.descriptions[$0.key, default: 0] += $0.value }
                }
                guard merged.seconds > 0 || forced[i] != nil else { continue }
                merged.seconds = max(merged.seconds, forced[i] != nil ? 60 : 0)
                merged.reasons["door jou toegewezen"] = max(merged.seconds, 1)
                minutes[i] = [m.key: merged]
                pinned[i] = true
                if forced[i] != nil { forced[i] = m.key }
            }
        }

        // 3. Per minuut: gewerkt? en voor wie?
        var keyAt = [String?](repeating: nil, count: n)
        var worked = 0.0
        for i in 0..<n {
            if let f = forced[i] {
                keyAt[i] = f
                worked += 60
                continue
            }
            let total = minutes[i].values.reduce(0) { $0 + $1.seconds }
            guard total >= minSecondsPerMinute else { continue }
            worked += min(total, 60)
            keyAt[i] = minutes[i].max { $0.value.seconds < $1.value.seconds }?.key
        }

        // 4. Wat al in Teamleader staat of genegeerd werd, valt weg
        var covered = [Bool](repeating: false, count: n)
        func cover(_ a: Double, _ b: Double) {
            let i0 = max(0, Int(((a - lo) / 60).rounded(.down)))
            let i1 = min(n, Int(((b - lo) / 60).rounded(.up)))
            if i0 < i1 { for i in i0..<i1 { covered[i] = true } }
        }
        // Wat TimeTrack zelf registreerde, dekt de echte blokken (ook bij een gebundelde registratie);
        // andere registraties dekken hun tijdstip in Teamleader.
        let pushed = Store.pushedParts(ids: registered.map(\.id))
        for r in registered {
            if let parts = pushed[r.id] {
                parts.forEach { cover($0.0, $0.1) }
            } else if let s = r.start, let e = r.end {
                cover(s, e)
            }
        }
        for (a, b) in dismissed ?? Store.dismissed(from: lo, to: hi) { cover(a, b) }

        func runs() -> [Run] {
            var out: [Run] = []
            var i = 0
            while i < n {
                guard !covered[i], let k = keyAt[i] else { i += 1; continue }
                var j = i
                while j < n, !covered[j], keyAt[j] == k { j += 1 }
                out.append(Run(key: k, from: i, to: j))
                i = j
            }
            return out
        }

        // 5. Gladstrijken
        // a. korte pauzes (koffie, telefoon) binnen hetzelfde werk overbruggen, maar geen privé-minuten
        var i = 0
        while i < n {
            guard keyAt[i] == nil, !covered[i] else { i += 1; continue }
            var j = i
            while j < n, keyAt[j] == nil, !covered[j], skippedSeconds[j] < minSecondsPerMinute { j += 1 }
            if j == i { i += 1; continue }
            if j - i <= bridgeMinutes, i > 0, j < n, !covered[i - 1], !covered[j],
               let k = keyAt[i - 1], keyAt[j] == k {
                for x in i..<j { keyAt[x] = k }
            }
            i = j
        }
        // b. korte uitstapjes opslorpen in het omringende werk
        for _ in 0..<3 {
            var changed = false
            let all = runs()
            for (idx, r) in all.enumerated() {
                let prev: Run? = idx > 0 && all[idx - 1].to == r.from ? all[idx - 1] : nil
                let next: Run? = idx + 1 < all.count && all[idx + 1].from == r.to ? all[idx + 1] : nil
                var target: String?
                if r.length < minProposalMinutes, let p = prev, let q = next, p.key == q.key {
                    target = p.key
                } else if r.key.isEmpty, r.length < absorbUnassignedMinutes {
                    target = [prev, next].compactMap { $0 }.filter { !$0.key.isEmpty }.max { $0.length < $1.length }?.key
                } else if r.length < minProposalMinutes, !(bundle && !r.key.isEmpty) {
                    // Bij bundelen blijven korte blokken van een herkende klant behouden: ze tellen op.
                    target = [prev, next].compactMap { $0 }.max { $0.length < $1.length }?.key
                }
                if let target, target != r.key, !pinned[r.from] {
                    for x in r.from..<r.to { keyAt[x] = target }
                    changed = true
                }
            }
            if !changed { break }
        }

        // c. Niet-herkend werk in een AI-assistent (Claude, ChatGPT…) hoort meestal bij de klant waaraan je
        //    vlak ervoor of erna werkte: die klant krijgt het, met de reden erbij.
        let assistantRuns = runs().filter { r in
            r.key.isEmpty && (r.from..<r.to).reduce(0) { $0 + assistantSeconds[$1] } >= Double(r.length) * 30
        }
        for r in assistantRuns {
            let all = runs().filter { !$0.key.isEmpty && $0.key != "skip" }
            let before = all.last { $0.to <= r.from && r.from - $0.to <= assistantContextMinutes }
            let after = all.first { $0.from >= r.to && $0.from - r.to <= assistantContextMinutes }
            guard let neighbour = before ?? after, let match = matches[neighbour.key] else { continue }
            for x in r.from..<r.to {
                guard var info = minutes[x][""] else { continue }
                let assistantName = info.activities.max { $0.value < $1.value }?.key.split(separator: ":").first.map(String.init) ?? "AI"
                info.reasons = ["\(assistantName) \(before != nil ? "na" : "voor") werk voor \(match.companyName)": info.seconds]
                var merged = minutes[x][neighbour.key] ?? Info()
                merged.seconds += info.seconds
                info.reasons.forEach { merged.reasons[$0.key, default: 0] += $0.value }
                info.activities.forEach { merged.activities[$0.key, default: 0] += $0.value }
                info.learn.forEach { merged.learn[$0.key, default: 0] += $0.value }
                minutes[x][neighbour.key] = merged
                minutes[x][""] = nil
                keyAt[x] = neighbour.key
            }
        }

        // 6. Voorstellen: één per aaneengesloten blok, of (bundelen) één per klant voor de hele dag.
        //    Bij bundelen tellen ook korte blokken van een herkende klant mee, want wie vaak wisselt,
        //    werkt verspreid over de dag in kleine stukken voor dezelfde klant.
        func top(_ d: [String: Double], _ k: Int) -> [(String, Double)] {
            d.sorted { $0.value > $1.value }.prefix(k).map { ($0.key, $0.value) }
        }
        let step = Double(max(roundTo, 1) * 60)
        var groups: [[Run]] = []
        var groupIndex: [String: Int] = [:]
        for r in runs() where r.key != "skip" {
            if bundle && !r.key.isEmpty {
                if let g = groupIndex[r.key] { groups[g].append(r) } else {
                    groupIndex[r.key] = groups.count
                    groups.append([r])
                }
            } else if r.length >= minProposalMinutes {
                groups.append([r])
            }
        }
        var proposals: [Proposal] = []
        for group in groups {
            let key = group[0].key
            var info = Info()
            for r in group {
                for x in r.from..<r.to {
                    guard let part = minutes[x][key] else { continue }
                    info.seconds += part.seconds
                    part.reasons.forEach { info.reasons[$0.key, default: 0] += $0.value }
                    part.activities.forEach { info.activities[$0.key, default: 0] += $0.value }
                    part.learn.forEach { info.learn[$0.key, default: 0] += $0.value }
                    part.descriptions.forEach { info.descriptions[$0.key, default: 0] += $0.value }
                }
            }
            let match = matches[key] ?? .unassigned
            var parts = group.map { Proposal.Part(start: lo + Double($0.from) * 60, end: lo + Double($0.to) * 60) }
            let worked = parts.reduce(0) { $0 + $1.end - $1.start }
            guard worked >= Double(minProposalMinutes * 60) else { continue }
            var seconds = worked
            if roundTo > 1 {
                seconds = max(step, (worked / step).rounded() * step)
                if group.count == 1 {
                    // Eén blok: afronden, maar nooit over een bestaande registratie of het volgende blok heen.
                    var free = group[0].to
                    while free < n, !covered[free], keyAt[free] == nil { free += 1 }
                    parts[0].end = min(parts[0].start + seconds, lo + Double(free) * 60)
                    seconds = parts[0].end - parts[0].start
                }
            }
            let reasons = match.isAssigned
                ? top(info.reasons, 2).map { "\($0.0) · \(formatDuration($0.1))" }
                : []
            proposals.append(Proposal(
                start: parts[0].start, end: parts[parts.count - 1].end, match: match, reasons: reasons,
                activities: top(info.activities.filter { $0.value >= 30 }, 4).map { "\($0.0) · \(formatDuration($0.1))" },
                description: match.description.isEmpty ? (top(info.descriptions, 1).first?.0 ?? "") : match.description,
                learnPattern: top(info.learn, 1).first?.0 ?? "",
                parts: parts, seconds: seconds, bundled: group.count > 1 || (bundle && !key.isEmpty)))
        }
        proposals.sort { $0.start < $1.start }

        // 7. Registraties in Teamleader zonder tijdstip (enkel duur) aftrekken: eerst bij dezelfde klant,
        //    dan bij niet-herkend werk, dan bij de rest; telkens van het einde van het laatste voorstel.
        for entry in registered where entry.start == nil {
            var remaining = entry.duration
            let companyId = entry.companyId
            let order = proposals.indices.sorted { a, b in
                func rank(_ p: Proposal) -> Int {
                    if companyId != nil && p.match.companyId == companyId { return 0 }
                    return p.match.isAssigned ? 2 : 1
                }
                let ra = rank(proposals[a]), rb = rank(proposals[b])
                return ra != rb ? ra < rb : proposals[a].start > proposals[b].start
            }
            for k in order where remaining > 0 {
                let take = min(remaining, proposals[k].duration)
                proposals[k].shorten(by: take)
                remaining -= take
            }
        }
        proposals.removeAll { $0.duration < Double(minProposalMinutes * 60) }

        return DayPlan(worked: worked, proposals: proposals, registered: registered, activity: activity)
    }
}
