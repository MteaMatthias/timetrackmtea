import Foundation
import SwiftUI

// MARK: - Modellen

/// Correctieregel: koppelt activiteiten (programma, venstertitel of website) aan een klant of negeert ze.
struct Rule: Identifiable, Hashable {
    var id: Int64 = 0
    var field = "any"            // "title", "app" of "any" (programma, titel én website)
    var pattern = ""             // trefwoorden, gescheiden door |
    var skip = false             // true = negeren (privé, niet registreren)
    var companyId: String?
    var companyName = ""
    var workTypeId: String?
    var workTypeName = ""
    var description = ""
    var invoiceable = true

    var targetLabel: String {
        if skip { return "Genegeerd" }
        return companyName.isEmpty ? "(geen klant)" : companyName
    }
}

/// Een bedrijf uit Teamleader, met de domeinen van zijn website en e-mailadressen.
struct Company: Identifiable, Hashable {
    let id: String
    let name: String
    let domains: [String]
    var phones: [String] = []     // genormaliseerd, zie Phone.key
}

/// Een oproep (Flow) of meeting (Teams, Zoom, Meet, Loom) en de klant ervan.
struct CallRecord: Identifiable, Hashable {
    var id: Int64 = 0
    var start: Double
    var end: Double
    var kind: Kind
    var label: String             // bv. "0493 29 50 63" of de titel van de meeting
    var detail = ""               // bv. "Matthias · M&M"
    var memoryKey = ""            // "tel:493295063" of "meet:weekoverleg janssen"
    var companyId: String?
    var companyName = ""
    var skip = false
    var confirmed = false

    enum Kind: String { case phone, meeting }

    var match: Match {
        skip ? Match(skip: true) : Match(companyId: companyId, companyName: companyName)
    }
}

/// Telefoonnummers vergelijken ongeacht de schrijfwijze: de laatste 9 cijfers (zonder landcode of 0).
enum Phone {
    static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    static func key(_ s: String) -> String? {
        // Zelfde nummer, andere schrijfwijze: "056 11 09 59", "+32 56 11 09 59" en "0032 56 11 09 59"
        // geven dezelfde sleutel. Belgische vaste nummers hebben 8 cijfers na de 0, gsm-nummers 9.
        var d = digits(s)
        if d.hasPrefix("00") { d.removeFirst(2) } else if d.hasPrefix("0") { d.removeFirst() }
        if d.hasPrefix("32"), (10...11).contains(d.count) { d.removeFirst(2) }
        guard d.count >= 8 else { return nil }
        return String(d.suffix(9))
    }

    /// Ziet eruit als een telefoonnummer (bv. "0493 29 50 63", "+32 56 11 09 59").
    static func looksLikeNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first == "+" || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "+0123456789 ./-()")
        return t.unicodeScalars.allSatisfy { allowed.contains($0) } && (8...16).contains(digits(t).count)
    }
}

struct Segment: Identifiable {
    let id: Int
    var start: Double
    var end: Double
    let app: String
    let title: String
    let host: String

    var duration: Double { end - start }
    var isIdle: Bool { app == Store.idleApp }
}

// MARK: - Opslag

enum Store {
    static let idleApp = "__idle__"

    /// Gaat omhoog bij elke wijziging aan regels, bedrijven of uitsluitingen (voor de Matcher-cache).
    private(set) static var dataVersion = 0
    private static let versionLock = NSLock()
    static func bumpDataVersion() {
        versionLock.lock(); dataVersion += 1; versionLock.unlock()
    }

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
                 workTypeName: r.string("work_type_name"), description: r.string("description"),
                 invoiceable: r.int("invoiceable") != 0)
        }.sorted { a, b in
            let pa = a.field == "app" ? 1 : 0, pb = b.field == "app" ? 1 : 0
            if pa != pb { return pa < pb }
            if a.pattern.count != b.pattern.count { return a.pattern.count > b.pattern.count }
            return a.id < b.id
        }
    }

    static func save(_ r: Rule) {
        defer { bumpDataVersion() }
        if r.id == 0 {
            Database.shared.run("""
                INSERT INTO rules(field, pattern, skip, company_id, company_name, work_type_id, work_type_name,
                description, invoiceable) VALUES (?,?,?,?,?,?,?,?,?)
                """, r.field, r.pattern, r.skip, r.companyId, r.companyName, r.workTypeId, r.workTypeName,
                r.description, r.invoiceable)
        } else {
            Database.shared.run("""
                UPDATE rules SET field=?, pattern=?, skip=?, company_id=?, company_name=?, work_type_id=?,
                work_type_name=?, description=?, invoiceable=? WHERE id=?
                """, r.field, r.pattern, r.skip, r.companyId, r.companyName, r.workTypeId, r.workTypeName,
                r.description, r.invoiceable, r.id)
        }
    }

    static func delete(rule: Rule) {
        Database.shared.run("DELETE FROM rules WHERE id=?", rule.id)
        bumpDataVersion()
    }

    // MARK: Bedrijven (cache van Teamleader)

    static func companies() -> [Company] {
        Database.shared.query("SELECT id, name, domains, phones FROM companies").map { r in
            Company(id: r.string("id"), name: r.string("name"),
                    domains: r.string("domains").split(separator: " ").map(String.init),
                    phones: r.string("phones").split(separator: " ").map(String.init))
        }
    }

    static func replaceCompanies(_ companies: [Company]) {
        guard !companies.isEmpty else { return }
        defer { bumpDataVersion() }
        Database.shared.transaction {
            Database.shared.run("DELETE FROM companies")
            for c in companies {
                Database.shared.run("INSERT OR REPLACE INTO companies(id, name, domains, phones) VALUES (?,?,?,?)",
                                    c.id, c.name, c.domains.joined(separator: " "), c.phones.joined(separator: " "))
            }
        }
    }

    static func companyName(id: String) -> String? {
        Database.shared.query("SELECT name FROM companies WHERE id=?", id).first?.optionalString("name")
    }

    // MARK: Activiteit

    static func segments(from lo: Double, to hi: Double) -> [Segment] {
        let rows = Database.shared.query(
            "SELECT start, end, app, title, host FROM activity WHERE end > ? AND start < ? ORDER BY start", lo, hi)
        return rows.enumerated().compactMap { (i, r) -> Segment? in
            let a = max(r.double("start"), lo), b = min(r.double("end"), hi)
            guard b > a else { return nil }
            return Segment(id: i, start: a, end: b, app: r.string("app"), title: r.string("title"),
                           host: r.string("host"))
        }
    }

    /// Staat dit nummer (genormaliseerd) al bij een bedrijf in de lokale lijst?
    static func companyHasPhone(_ key: String) -> Bool {
        !Database.shared.query("SELECT id FROM companies WHERE (' ' || phones || ' ') LIKE ?", "% \(key) %").isEmpty
    }

    static func addCompanyPhone(companyId: String, key: String) {
        Database.shared.run("UPDATE companies SET phones = trim(phones || ' ' || ?) WHERE id=?", key, companyId)
        bumpDataVersion()
    }

    // MARK: Oproepen en meetings

    static func calls(from lo: Double, to hi: Double) -> [CallRecord] {
        Database.shared.query("SELECT * FROM calls WHERE end > ? AND start < ? ORDER BY start", lo, hi).map(callRecord)
    }

    private static func callRecord(_ r: Row) -> CallRecord {
        CallRecord(id: r["id"] as? Int64 ?? 0, start: r.double("start"), end: r.double("end"),
                   kind: CallRecord.Kind(rawValue: r.string("kind")) ?? .meeting, label: r.string("label"),
                   detail: r.string("detail"), memoryKey: r.string("memory_key"),
                   companyId: r.optionalString("company_id"), companyName: r.string("company_name"),
                   skip: r.int("skip") == 1, confirmed: r.int("confirmed") == 1)
    }

    @discardableResult
    static func save(_ c: CallRecord) -> Int64 {
        if c.id == 0 {
            return Database.shared.run("""
                INSERT INTO calls(start, end, kind, label, detail, memory_key, company_id, company_name, skip, confirmed)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, c.start, c.end, c.kind.rawValue, c.label, c.detail, c.memoryKey, c.companyId, c.companyName,
                c.skip, c.confirmed)
        }
        Database.shared.run("""
            UPDATE calls SET start=?, end=?, label=?, detail=?, company_id=?, company_name=?, skip=?, confirmed=?
            WHERE id=?
            """, c.start, c.end, c.label, c.detail, c.companyId, c.companyName, c.skip, c.confirmed, c.id)
        return c.id
    }

    static func deleteCall(id: Int64) {
        Database.shared.run("DELETE FROM calls WHERE id=?", id)
    }

    /// Wat de gebruiker eerder koos voor dit nummer of deze meeting.
    static func callMemory(_ key: String) -> Match? {
        guard !key.isEmpty, let r = Database.shared.query("SELECT * FROM call_memory WHERE key=?", key).first else {
            return nil
        }
        return r.int("skip") == 1 ? Match(skip: true)
            : Match(companyId: r.optionalString("company_id"), companyName: r.string("company_name"))
    }

    static func remember(_ key: String, _ match: Match) {
        guard !key.isEmpty else { return }
        Database.shared.run("INSERT OR REPLACE INTO call_memory(key, company_id, company_name, skip) VALUES (?,?,?,?)",
                            key, match.companyId, match.companyName, match.skip)
    }

    // MARK: Bewaartermijn

    /// Activiteit, gesprekken en genegeerde/toegewezen blokken ouder dan 90 dagen wissen.
    static func pruneOldActivity(days: Int = 90) {
        let limit = Date().timeIntervalSince1970 - Double(days) * 86400
        for table in ["activity", "calls", "dismissed", "assignments", "pushed"] {
            Database.shared.run("DELETE FROM \(table) WHERE end < ?", limit)
        }
    }

    /// "Wis mijn activiteit": alles wat bijgehouden werd, niet de regels of instellingen.
    /// Wist alles wat TimeTrack op één dag bijhield (activiteit, gesprekken, toewijzingen, genegeerde blokken).
    /// Registraties in Teamleader blijven staan. Iets dat over middernacht loopt, wordt afgeknipt.
    static func wipeDay(from lo: Double, to hi: Double) {
        Database.shared.transaction {
            for table in ["activity", "calls", "dismissed", "assignments"] {
                Database.shared.run("DELETE FROM \(table) WHERE start >= ? AND start < ?", lo, hi)
                Database.shared.run("UPDATE \(table) SET end = ? WHERE start < ? AND end > ?", lo, lo, lo)
                Database.shared.run("UPDATE \(table) SET start = ? WHERE start < ? AND end > ?", hi, hi, hi)
            }
        }
        bumpDataVersion()
    }

    static func wipeActivity() {
        for table in ["activity", "calls", "dismissed", "assignments"] {
            Database.shared.run("DELETE FROM \(table)")
        }
    }

    // MARK: Zelf toegewezen blokken

    struct Assignment {
        let start: Double
        let end: Double
        let match: Match
    }

    static func assignments(from lo: Double, to hi: Double) -> [Assignment] {
        Database.shared.query("SELECT * FROM assignments WHERE end > ? AND start < ? ORDER BY id", lo, hi).map {
            Assignment(start: $0.double("start"), end: $0.double("end"),
                       match: Match(companyId: $0.optionalString("company_id"), companyName: $0.string("company_name")))
        }
    }

    /// Wijst een blok toe aan een klant; een eerdere toewijzing van (een deel van) dit blok vervalt.
    static func assign(start: Double, end: Double, to match: Match) {
        Database.shared.transaction {
            Database.shared.run("DELETE FROM assignments WHERE start >= ? AND end <= ?", start, end)
            Database.shared.run("INSERT INTO assignments(start, end, company_id, company_name) VALUES (?,?,?,?)",
                                start, end, match.companyId, match.companyName)
        }
    }

    // MARK: Geregistreerde blokken

    static func savePushed(teamleaderId: String, parts: [Proposal.Part]) {
        Database.shared.transaction {
            for p in parts {
                Database.shared.run("INSERT INTO pushed(tl_id, start, end) VALUES (?,?,?)", teamleaderId, p.start, p.end)
            }
        }
    }

    static func deletePushed(teamleaderId: String) {
        Database.shared.run("DELETE FROM pushed WHERE tl_id=?", teamleaderId)
    }

    static func pushedParts(ids: [String]) -> [String: [(Double, Double)]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var out: [String: [(Double, Double)]] = [:]
        let rows = Database.shared.queryArgs("SELECT tl_id, start, end FROM pushed WHERE tl_id IN (\(placeholders))", ids)
        for r in rows { out[r.string("tl_id"), default: []].append((r.double("start"), r.double("end"))) }
        return out
    }

    // MARK: Genegeerde voorstellen

    static func dismissed(from lo: Double, to hi: Double) -> [(Double, Double)] {
        Database.shared.query("SELECT start, end FROM dismissed WHERE end > ? AND start < ?", lo, hi)
            .map { ($0.double("start"), $0.double("end")) }
    }

    static func dismiss(start: Double, end: Double) {
        Database.shared.run("INSERT INTO dismissed(start, end) VALUES (?,?)", start, end)
    }

    static func undismiss(from lo: Double, to hi: Double) {
        Database.shared.run("DELETE FROM dismissed WHERE end > ? AND start < ?", lo, hi)
    }
}

// MARK: - Opmaak

func formatDuration(_ seconds: Double) -> String {
    let m = Int((seconds / 60).rounded())
    return m < 60 ? "\(m) min" : String(format: "%ldu%02ld", m / 60, m % 60)
}

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
