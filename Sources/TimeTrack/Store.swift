import Foundation
import SwiftUI

// MARK: - Modellen

/// Koppelt activiteiten (programma en/of venstertitel) aan een Teamleader-klant.
struct Rule: Identifiable, Hashable {
    var id: Int64 = 0
    var field = "title"          // "title", "app" of "any"
    var pattern = ""             // trefwoorden, gescheiden door |
    var skip = false             // true = negeren (privé, niet registreren)
    var companyId: String?
    var companyName = ""
    var workTypeId: String?
    var workTypeName = ""
    var description = ""

    var targetLabel: String {
        if skip { return "Genegeerd" }
        return companyName.isEmpty ? "(geen klant)" : companyName
    }
}

/// Een (concept)registratie die naar Teamleader kan worden gestuurd.
struct Entry: Identifiable, Hashable {
    var id: Int64 = 0
    var day = ""
    var start: Double = Date().timeIntervalSince1970
    var minutes = 60
    var companyId: String?
    var companyName = ""
    var workTypeId: String?
    var workTypeName = ""
    var description = ""
    var invoiceable = true
    var auto = false
    var groupKey: String?
    var pushedId: String?
    var error: String?

    var isPushed: Bool { pushedId != nil }
    var isReady: Bool { !isPushed && minutes > 0 && companyId != nil }
    var startDate: Date { Date(timeIntervalSince1970: start) }
}

struct Segment: Identifiable {
    let id: Int
    var start: Double
    var end: Double
    let app: String
    let title: String
    let rule: Rule?

    var duration: Double { end - start }
    var isIdle: Bool { app == Store.idleApp }
    var counts: Bool { !isIdle && !(rule?.skip ?? false) }
    var label: String {
        if isIdle { return "Inactief" }
        return rule?.targetLabel ?? "Niet toegewezen"
    }
    var color: Color {
        if isIdle { return .clear }
        guard let rule else { return .gray.opacity(0.55) }
        return rule.skip ? .gray.opacity(0.25) : Color.forName(rule.targetLabel)
    }
}

struct ActivityGroup: Identifiable {
    var id: String { app + "\u{1}" + title }
    let app: String
    let title: String
    var seconds: Double
    let rule: Rule?
}

// MARK: - Classificatie

/// Titelregels gaan voor programmaregels; bij meerdere treffers wint het langste patroon.
final class Classifier {
    private let rules: [(rule: Rule, terms: [String])]
    private var cache: [String: Rule?] = [:]

    init(rules: [Rule] = Store.rules()) {
        self.rules = rules.map { rule in
            (rule, rule.pattern.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        }
    }

    func match(app: String, title: String) -> Rule? {
        if app == Store.idleApp { return nil }
        let key = app + "\u{1}" + title
        if let cached = cache[key] { return cached }
        let a = app.lowercased(), t = title.lowercased()
        let found = rules.first { item in
            let text: String
            switch item.rule.field {
            case "app": text = a
            case "title": text = t
            default: text = a + " " + t
            }
            return item.terms.contains { text.contains($0) }
        }?.rule
        cache[key] = .some(found)
        return found
    }
}

// MARK: - Opslag

enum Store {
    static let idleApp = "__idle__"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func dayBounds(_ date: Date) -> (Double, Double) {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    // MARK: Regels

    static func rules() -> [Rule] {
        Database.shared.query("SELECT * FROM rules").map { r in
            Rule(id: r["id"] as? Int64 ?? 0, field: r.string("field"), pattern: r.string("pattern"),
                 skip: r.int("skip") == 1, companyId: r.optionalString("company_id"),
                 companyName: r.string("company_name"), workTypeId: r.optionalString("work_type_id"),
                 workTypeName: r.string("work_type_name"), description: r.string("description"))
        }.sorted { a, b in
            let pa = a.field == "app" ? 1 : 0, pb = b.field == "app" ? 1 : 0
            if pa != pb { return pa < pb }
            if a.pattern.count != b.pattern.count { return a.pattern.count > b.pattern.count }
            return a.id < b.id
        }
    }

    static func save(_ r: Rule) {
        if r.id == 0 {
            Database.shared.run("""
                INSERT INTO rules(field, pattern, skip, company_id, company_name, work_type_id, work_type_name, description)
                VALUES (?,?,?,?,?,?,?,?)
                """, r.field, r.pattern, r.skip, r.companyId, r.companyName, r.workTypeId, r.workTypeName, r.description)
        } else {
            Database.shared.run("""
                UPDATE rules SET field=?, pattern=?, skip=?, company_id=?, company_name=?, work_type_id=?,
                work_type_name=?, description=? WHERE id=?
                """, r.field, r.pattern, r.skip, r.companyId, r.companyName, r.workTypeId, r.workTypeName,
                r.description, r.id)
        }
    }

    static func delete(rule: Rule) {
        Database.shared.run("DELETE FROM rules WHERE id=?", rule.id)
    }

    // MARK: Activiteit

    static func segments(day: Date, classifier: Classifier = Classifier()) -> [Segment] {
        let (lo, hi) = dayBounds(day)
        let rows = Database.shared.query(
            "SELECT start, end, app, title FROM activity WHERE end > ? AND start < ? ORDER BY start", lo, hi)
        return rows.enumerated().compactMap { (i, r) -> Segment? in
            let a = max(r.double("start"), lo), b = min(r.double("end"), hi)
            guard b > a else { return nil }
            let app = r.string("app"), title = r.string("title")
            return Segment(id: i, start: a, end: b, app: app, title: title,
                           rule: classifier.match(app: app, title: title))
        }
    }

    static func groups(of segments: [Segment]) -> [ActivityGroup] {
        var map: [String: ActivityGroup] = [:]
        for s in segments where !s.isIdle {
            let key = s.app + "\u{1}" + s.title
            map[key, default: ActivityGroup(app: s.app, title: s.title, seconds: 0, rule: s.rule)].seconds += s.duration
        }
        return map.values.sorted { $0.seconds > $1.seconds }
    }

    /// Voegt opeenvolgende stukken met hetzelfde label samen (voor de tijdlijn).
    static func merged(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segments {
            if let last = out.last, last.label == s.label, s.start - last.end < 60 {
                out[out.count - 1].end = s.end
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: Registraties

    static func entries(from: Date, to: Date) -> [Entry] {
        Database.shared.query("SELECT * FROM entries WHERE day BETWEEN ? AND ? ORDER BY start",
                              dayKey(from), dayKey(to)).map(entry)
    }

    private static func entry(_ r: Row) -> Entry {
        Entry(id: r["id"] as? Int64 ?? 0, day: r.string("day"), start: r.double("start"), minutes: r.int("minutes"),
              companyId: r.optionalString("company_id"), companyName: r.string("company_name"),
              workTypeId: r.optionalString("work_type_id"), workTypeName: r.string("work_type_name"),
              description: r.string("description"), invoiceable: r.int("invoiceable") == 1,
              auto: r.int("auto") == 1, groupKey: r.optionalString("group_key"),
              pushedId: r.optionalString("pushed_id"), error: r.optionalString("error"))
    }

    @discardableResult
    static func save(_ e: Entry) -> Int64 {
        let day = dayKey(e.startDate)
        if e.id == 0 {
            return Database.shared.run("""
                INSERT INTO entries(day, start, minutes, company_id, company_name, work_type_id, work_type_name,
                description, invoiceable, auto, group_key) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, day, e.start, e.minutes, e.companyId, e.companyName, e.workTypeId, e.workTypeName,
                e.description, e.invoiceable, e.auto, e.groupKey)
        }
        Database.shared.run("""
            UPDATE entries SET day=?, start=?, minutes=?, company_id=?, company_name=?, work_type_id=?,
            work_type_name=?, description=?, invoiceable=?, auto=?, error=NULL WHERE id=?
            """, day, e.start, e.minutes, e.companyId, e.companyName, e.workTypeId, e.workTypeName,
            e.description, e.invoiceable, e.auto, e.id)
        return e.id
    }

    static func delete(entryId: Int64) {
        Database.shared.run("DELETE FROM entries WHERE id=?", entryId)
    }

    static func markPushed(_ id: Int64, teamleaderId: String) {
        Database.shared.run("UPDATE entries SET pushed_id=?, pushed_at=?, error=NULL WHERE id=?",
                            teamleaderId, Date().timeIntervalSince1970, id)
    }

    static func markError(_ id: Int64, _ message: String) {
        Database.shared.run("UPDATE entries SET error=? WHERE id=?", message, id)
    }

    /// Maakt conceptregistraties voor een dag: één per klant/werksoort/omschrijving.
    /// Eerder gegenereerde, nog niet verstuurde en niet bewerkte concepten worden vervangen;
    /// wat al naar Teamleader ging, wordt afgetrokken.
    static func generateDrafts(day: Date, roundTo: Int) -> (created: Int, unassigned: Double) {
        let key = dayKey(day)
        Database.shared.run("DELETE FROM entries WHERE day=? AND auto=1 AND pushed_id IS NULL", key)

        struct Acc { var rule: Rule; var start: Double; var seconds: Double; var titles: [String: Double] }
        var groups: [String: Acc] = [:]
        var unassigned = 0.0
        for s in segments(day: day) where !s.isIdle {
            guard let rule = s.rule else { unassigned += s.duration; continue }
            if rule.skip { continue }
            let gk = [rule.companyId ?? rule.companyName, rule.workTypeId ?? "", rule.description]
                .joined(separator: "\u{1}")
            var acc = groups[gk] ?? Acc(rule: rule, start: s.start, seconds: 0, titles: [:])
            acc.seconds += s.duration
            acc.titles[s.title.isEmpty ? s.app : s.title, default: 0] += s.duration
            groups[gk] = acc
        }

        // Minuten die al bestaan voor dezelfde groep (verstuurd of handmatig bewerkt).
        var existing: [String: Int] = [:]
        for r in Database.shared.query("SELECT group_key, minutes FROM entries WHERE day=? AND group_key IS NOT NULL", key) {
            existing[r.string("group_key"), default: 0] += r.int("minutes")
        }

        var created = 0
        let step = max(roundTo, 1)
        for (gk, acc) in groups.sorted(by: { $0.value.start < $1.value.start }) {
            let rounded = Int((acc.seconds / 60 / Double(step)).rounded()) * step
            let minutes = rounded - existing[gk, default: 0]
            guard minutes > 0 else { continue }
            let description = acc.rule.description.isEmpty
                ? acc.titles.sorted { $0.value > $1.value }.prefix(3).map { String($0.key.prefix(60)) }.joined(separator: ", ")
                : acc.rule.description
            save(Entry(start: acc.start, minutes: minutes, companyId: acc.rule.companyId,
                       companyName: acc.rule.companyName, workTypeId: acc.rule.workTypeId,
                       workTypeName: acc.rule.workTypeName, description: description, auto: true, groupKey: gk))
            created += 1
        }
        return (created, unassigned)
    }
}

// MARK: - Opmaak

func formatDuration(_ seconds: Double) -> String {
    let m = Int((seconds / 60).rounded())
    return m < 60 ? "\(m) min" : String(format: "%ldu%02ld", m / 60, m % 60)
}

func formatMinutes(_ minutes: Int) -> String { formatDuration(Double(minutes * 60)) }

func formatTime(_ t: Double) -> String {
    Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened)
}

extension Color {
    /// Vaste kleur per naam (String.hashValue verschilt per opstart, dus eigen hash).
    static func forName(_ name: String) -> Color {
        var h: UInt32 = 0
        for u in name.unicodeScalars { h = h &* 31 &+ u.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

extension Date {
    var startOfWeek: Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: self)?.start ?? self
    }
}
