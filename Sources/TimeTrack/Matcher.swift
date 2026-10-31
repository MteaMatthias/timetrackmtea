import Foundation

/// Aan welke klant een stuk werk toebehoort, en waarom.
struct Match: Hashable {
    var companyId: String?
    var companyName = ""
    var workTypeId: String?
    var workTypeName = ""
    var description = ""
    var invoiceable = true
    var skip = false

    static let unassigned = Match()

    var isAssigned: Bool { !skip && !companyName.isEmpty }
    /// Groepeersleutel: "" = niet toegewezen.
    var key: String { skip ? "skip" : (companyId ?? (companyName.isEmpty ? "" : "naam:" + companyName)) }

    init(companyId: String? = nil, companyName: String = "", workTypeId: String? = nil, workTypeName: String = "",
         description: String = "", invoiceable: Bool = true, skip: Bool = false) {
        self.companyId = companyId
        self.companyName = companyName
        self.workTypeId = workTypeId
        self.workTypeName = workTypeName
        self.description = description
        self.invoiceable = invoiceable
        self.skip = skip
    }

    init(rule: Rule) {
        self.init(companyId: rule.companyId, companyName: rule.companyName, workTypeId: rule.workTypeId,
                  workTypeName: rule.workTypeName, description: rule.description, invoiceable: rule.invoiceable,
                  skip: rule.skip)
    }

    init(company: Company) {
        self.init(companyId: company.id, companyName: company.name)
    }
}

/// Herkent klanten automatisch op basis van de gegevens in Teamleader:
/// 1. correctieregels van de gebruiker,
/// 2. het domein van de bezochte website of van agenda-deelnemers (website en e-mailadressen van het bedrijf),
/// 3. de bedrijfsnaam in de venstertitel of de titel van de afspraak.
final class Matcher {
    private let rules: [(rule: Rule, terms: [String])]
    private let byDomain: [String: Company]
    private let byName: [(name: String, company: Company)]
    private var cache: [String: (Match, String)] = [:]

    /// Domeinen van mailproviders, tools en sociale media zeggen niets over de klant.
    static let genericDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "outlook.be", "hotmail.com", "hotmail.be", "live.com",
        "live.be", "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "telenet.be", "skynet.be",
        "proximus.be", "scarlet.be", "google.com", "microsoft.com", "office.com", "teamleader.eu",
        "focus.teamleader.eu", "linkedin.com", "facebook.com", "instagram.com", "youtube.com", "apple.com",
        "github.com", "wordpress.com", "wix.com", "shopify.com", "combell.com", "mtea.be",
    ]

    /// Woorden die een bedrijfsnaam niet herkenbaar maken in een venstertitel.
    private static let legalForms: Set<String> = [
        "bv", "bvba", "nv", "cv", "cvba", "vof", "commv", "srl", "sa", "sprl", "vzw", "asbl", "ltd", "gmbh",
        "inc", "llc", "bv.", "nv.", "the", "de", "het",
    ]

    init(rules: [Rule] = Store.rules(), companies: [Company] = Store.companies(), ownDomain: String? = nil) {
        self.rules = rules.map { rule in
            (rule, rule.pattern.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        }
        var domains: [String: Company] = [:]
        var names: [(name: String, company: Company)] = []
        for c in companies {
            for d in c.domains where !Self.genericDomains.contains(d) && d != ownDomain {
                domains[d] = domains[d] ?? c
            }
            let n = Self.normalize(c.name, stripLegalForms: true)
            if n.count >= 4 { names.append((name: n, company: c)) }
        }
        byDomain = domains
        byName = names.sorted { $0.name.count > $1.name.count }
    }

    /// Kleine letters, leestekens weg, rechtsvormen weg; omringd door spaties voor woordgrenzen.
    static func normalize(_ s: String, stripLegalForms: Bool = false) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let kept = stripLegalForms ? words.filter { !legalForms.contains($0) } : words
        return kept.joined(separator: " ")
    }

    static func registrableDomain(_ host: String) -> [String] {
        // "app.janssen.be" → ["app.janssen.be", "janssen.be"]
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return [host] }
        return (0...(parts.count - 2)).map { parts[$0...].joined(separator: ".") }
    }

    /// Match voor een venster. De reden is kort en leesbaar, bv. "website janssen.be".
    func match(app: String, title: String, host: String) -> (Match, String) {
        let cacheKey = [app, title, host].joined(separator: "\u{1}")
        if let hit = cache[cacheKey] { return hit }
        let result = compute(app: app, title: title, host: host)
        cache[cacheKey] = result
        return result
    }

    private func compute(app: String, title: String, host: String) -> (Match, String) {
        let a = app.lowercased(), t = title.lowercased(), h = host.lowercased()
        for item in rules {
            let text: String
            switch item.rule.field {
            case "app": text = a
            case "title": text = t + " " + h
            default: text = [a, t, h].joined(separator: " ")
            }
            if let term = item.terms.first(where: { text.contains($0) }) {
                return (Match(rule: item.rule), item.rule.skip ? "genegeerd (\(term))" : "regel ‘\(term)’")
            }
        }
        if !h.isEmpty {
            for d in Self.registrableDomain(h) {
                if let c = byDomain[d] { return (Match(company: c), "website \(h)") }
            }
        }
        let normTitle = " " + Self.normalize(title) + " "
        if normTitle.count > 2, let hit = byName.first(where: { normTitle.contains(" \($0.name) ") }) {
            let where_ = title.isEmpty ? app : "‘\(String(title.prefix(40)))’"
            return (Match(company: hit.company), "\(hit.company.name) in \(where_)")
        }
        return (.unassigned, host.isEmpty ? app : host)
    }

    /// Match voor een afspraak: regels op de titel, dan e-maildomeinen van deelnemers, dan de naam in de titel.
    func match(event: CalendarEvent) -> (Match, String)? {
        let t = event.title.lowercased()
        for item in rules where item.rule.field != "app" {
            if item.terms.contains(where: { t.contains($0) }) {
                return (Match(rule: item.rule), "agenda: \(event.title)")
            }
        }
        for email in event.attendeeEmails {
            guard let domain = email.split(separator: "@").last.map(String.init) else { continue }
            if let c = byDomain[domain] { return (Match(company: c), "afspraak met \(email)") }
        }
        let normTitle = " " + Self.normalize(event.title) + " "
        if let hit = byName.first(where: { normTitle.contains(" \($0.name) ") }) {
            return (Match(company: hit.company), "agenda: \(event.title)")
        }
        return nil
    }
}
