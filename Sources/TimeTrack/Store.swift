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
    }

    // MARK: Bedrijven (cache van Teamleader)

    static func companies() -> [Company] {
        Database.shared.query("SELECT id, name, domains FROM companies").map { r in
            Company(id: r.string("id"), name: r.string("name"),
                    domains: r.string("domains").split(separator: " ").map(String.init))
        }
    }

    static func replaceCompanies(_ companies: [Company]) {
        guard !companies.isEmpty else { return }
        Database.shared.run("DELETE FROM companies")
        for c in companies {
            Database.shared.run("INSERT OR REPLACE INTO companies(id, name, domains) VALUES (?,?,?)",
                                c.id, c.name, c.domains.joined(separator: " "))
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
