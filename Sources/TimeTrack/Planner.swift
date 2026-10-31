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
    var start: Double
    var end: Double
    var match: Match
    var reasons: [String]       // waarom deze klant, bv. "website janssen.be · 1u10"
    var activities: [String]    // wat je deed
    var description: String
    var learnPattern: String    // kandidaat voor een correctieregel (domein of programma)

    /// Blijft gelijk terwijl het lopende blok langer wordt, zodat bewerkingen op een kaart niet verloren gaan.
    var id: String { "\(Int(start))|\(match.key)" }
    var duration: Double { end - start }
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

    /// - Parameters:
    ///   - events: afspraken (nil = uit de agenda's op deze Mac); voor tests in te vullen.
    ///   - dismissed: genegeerde periodes (nil = uit de database).
    static func plan(day: Date, registered: [Registered], matcher: Matcher = Matcher(), roundTo: Int = 5,
                     events: [CalendarEvent]? = nil, dismissed: [(Double, Double)]? = nil) -> DayPlan {
        let (lo, hi) = Store.dayBounds(day)
        let n = max(1, Int(((hi - lo) / 60).rounded()))
        var minutes = [[String: Info]](repeating: [:], count: n)
        var forced = [String?](repeating: nil, count: n)
        var skippedSeconds = [Double](repeating: 0, count: n)
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
            let what = seg.host.isEmpty ? (seg.title.isEmpty ? seg.app : "\(seg.app): \(seg.title)") : "\(seg.app): \(seg.host)"
            let learn = seg.host.isEmpty ? seg.app : seg.host
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
        for r in registered { if let s = r.start, let e = r.end { cover(s, e) } }
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
                } else if r.length < minProposalMinutes {
                    target = [prev, next].compactMap { $0 }.max { $0.length < $1.length }?.key
                }
                if let target, target != r.key {
                    for x in r.from..<r.to { keyAt[x] = target }
                    changed = true
                }
            }
            if !changed { break }
        }

        // 6. Voorstellen
        var proposals: [Proposal] = []
        for r in runs() where r.length >= minProposalMinutes && r.key != "skip" {
            var info = Info()
            for x in r.from..<r.to {
                guard let part = minutes[x][r.key] else { continue }
                info.seconds += part.seconds
                part.reasons.forEach { info.reasons[$0.key, default: 0] += $0.value }
                part.activities.forEach { info.activities[$0.key, default: 0] += $0.value }
                part.learn.forEach { info.learn[$0.key, default: 0] += $0.value }
                part.descriptions.forEach { info.descriptions[$0.key, default: 0] += $0.value }
            }
            let match = matches[r.key] ?? .unassigned
            let start = lo + Double(r.from) * 60
            var end = lo + Double(r.to) * 60
            if roundTo > 1 {
                // Duur afronden, maar nooit over een bestaande registratie of het volgende blok heen.
                let step = Double(roundTo * 60)
                let rounded = max(step, ((end - start) / step).rounded() * step)
                var free = r.to
                while free < n, !covered[free], keyAt[free] == nil { free += 1 }
                end = min(start + rounded, lo + Double(free) * 60)
            }
            func top(_ d: [String: Double], _ k: Int) -> [(String, Double)] {
                d.sorted { $0.value > $1.value }.prefix(k).map { ($0.key, $0.value) }
            }
            let reasons = match.isAssigned
                ? top(info.reasons, 2).map { "\($0.0) · \(formatDuration($0.1))" }
                : []
            proposals.append(Proposal(
                start: start, end: end, match: match, reasons: reasons,
                activities: top(info.activities, 4).map { "\($0.0) · \(formatDuration($0.1))" },
                description: match.description.isEmpty ? (top(info.descriptions, 1).first?.0 ?? "") : match.description,
                learnPattern: top(info.learn, 1).first?.0 ?? ""))
        }

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
                proposals[k].end -= take
                remaining -= take
            }
        }
        proposals.removeAll { $0.duration < Double(minProposalMinutes * 60) }

        return DayPlan(worked: worked, proposals: proposals, registered: registered, activity: activity)
    }
}
