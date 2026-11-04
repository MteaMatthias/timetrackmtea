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

    init(company: Company, invoiceable: Bool = true) {
        self.init(companyId: company.id, companyName: company.name, invoiceable: invoiceable)
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
    private let byPhone: [String: Company]
    private var cache: [String: (Match, String)] = [:]
    private let cacheLock = NSLock()

    /// Domeinen van mailproviders, online tools en sociale media zeggen niets over de klant
    /// (ook al staan sommige als leverancier in Teamleader). Subdomeinen tellen mee.
    static let genericDomains: Set<String> = [
        // mail en internetproviders
        "gmail.com", "googlemail.com", "outlook.com", "outlook.be", "hotmail.com", "hotmail.be", "hotmail.fr",
        "live.com", "live.be", "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "yahoo.fr", "aol.com",
        "telenet.be", "skynet.be", "proximus.be", "scarlet.be", "pandora.be", "orange.fr", "orange.be", "base.be",
        "protonmail.com", "proton.me", "gmx.com", "gmx.net",
        // grote platformen en kantoortools
        "google.com", "google.be", "microsoft.com", "office.com", "office365.com", "live.net", "sharepoint.com",
        "apple.com", "teamleader.eu", "billit.be", "notion.so", "notion.site", "figma.com", "canva.com", "miro.com",
        "slack.com", "zoom.us", "webex.com", "atlassian.net", "atlassian.com", "trello.com", "asana.com",
        "monday.com", "clickup.com", "dropbox.com", "wetransfer.com", "box.com", "chatgpt.com", "openai.com",
        "claude.ai", "anthropic.com", "deepl.com", "grammarly.com", "loom.com", "calendly.com", "docusign.net",
        "adobe.com", "mailchimp.com", "hubspot.com", "semrush.com", "mollie.com", "stripe.com", "paypal.com",
        "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "wordpress.com", "wordpress.org",
        "wix.com", "shopify.com", "squarespace.com", "webflow.com", "combell.com", "cloudflare.com",
        // sociaal en media
        "linkedin.com", "facebook.com", "instagram.com", "x.com", "twitter.com", "youtube.com", "tiktok.com",
        "pinterest.com", "whatsapp.com", "spotify.com", "netflix.com", "wikipedia.org",
        // lokaal
        "localhost",
    ]

    /// Publieke achtervoegsels: "x.co.uk" → klantdomein is "x.co.uk", niet "co.uk".
    private static let publicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "com.au", "co.nz", "co.za", "com.br", "co.jp", "github.io", "gitlab.io",
        "vercel.app", "netlify.app", "herokuapp.com", "azurewebsites.net", "web.app", "firebaseapp.com",
        "pages.dev", "wixsite.com", "myshopify.com", "wordpress.com", "blogspot.com", "cloudfront.net",
        "amazonaws.com", "googleusercontent.com",
    ]

    /// True voor domeinen (of subdomeinen) die nooit een klant aanduiden.
    static func isGeneric(_ host: String) -> Bool {
        registrableDomain(host).contains { genericDomains.contains($0) }
    }

    /// Bedrijven die de gebruiker uitsloot (leveranciers, eigen bedrijf).
    static var excludedCompanies: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedCompanies") ?? [])
    }

    static func exclude(companyId: String, _ excluded: Bool = true) {
        var set = excludedCompanies
        if excluded { set.insert(companyId) } else { set.remove(companyId) }
        UserDefaults.standard.set(Array(set), forKey: "excludedCompanies")
        Store.bumpDataVersion()
    }

    /// Woorden die een bedrijfsnaam niet herkenbaar maken in een venstertitel.
    private static let legalForms: Set<String> = [
        "bv", "bvba", "nv", "cv", "cvba", "vof", "commv", "srl", "sa", "sprl", "vzw", "asbl", "ltd", "gmbh",
        "inc", "llc", "bv.", "nv.", "the", "de", "het",
    ]

    private let defaultInvoiceable: Bool

    /// Matcher met de huidige instellingen (regels, bedrijven, eigen domein, standaard factureerbaar).
    /// Hergebruikt zolang regels, bedrijven en uitsluitingen niet veranderden (Store.dataVersion),
    /// zodat herkenningen in de cache blijven en niet alles opnieuw uit de database komt.
    static func current() -> Matcher {
        currentLock.lock()
        defer { currentLock.unlock() }
        let version = Store.dataVersion
        if let cached = currentCache, cached.version == version { return cached.matcher }
        let matcher = Matcher(defaultInvoiceable: UserDefaults.standard.object(forKey: "tlInvoiceable") as? Bool ?? true)
        currentCache = (matcher, version)
        return matcher
    }
    private static var currentCache: (matcher: Matcher, version: Int)?
    private static let currentLock = NSLock()

    init(rules: [Rule] = Store.rules(), companies: [Company] = Store.companies(),
         ownDomain: String? = UserDefaults.standard.string(forKey: "tlOwnDomain"),
         excluded: Set<String> = Matcher.excludedCompanies, defaultInvoiceable: Bool = true,
         ownNames: [String] = Matcher.ownNames) {
        self.defaultInvoiceable = defaultInvoiceable
        let ownNormalized = Set(ownNames.map { Self.normalize($0, stripLegalForms: true) }.filter { !$0.isEmpty })
        self.rules = rules.map { rule in
            (rule, rule.pattern.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        }
        // Eigen bedrijf en uitgesloten bedrijven (leveranciers) nooit als klant herkennen.
        // Ook een "bedrijf" met je eigen naam (voor- of volledige naam) nooit: die staat in venstertitels
        // (bv. de profielnaam van Chrome) en zou alles aan dat bedrijf koppelen.
        let candidates = companies.filter { c in
            !excluded.contains(c.id) && !(ownDomain.map { c.domains.contains($0) } ?? false)
                && !ownNormalized.contains(Self.normalize(c.name, stripLegalForms: true))
        }
        var owners: [String: [Company]] = [:]
        var names: [(name: String, company: Company)] = []
        for c in candidates {
            for d in c.domains where !Self.isGeneric(d) && !Self.publicSuffixes.contains(d) {
                owners[d, default: []].append(c)
            }
            let n = Self.normalize(c.name, stripLegalForms: true)
            if n.count >= 4 { names.append((name: n, company: c)) }
        }
        // Een domein van meerdere bedrijven (gedeelde hosting, mailprovider) is niet eenduidig.
        byDomain = owners.compactMapValues { $0.count == 1 ? $0[0] : nil }
        var phoneOwners: [String: [Company]] = [:]
        for c in candidates { for p in c.phones { phoneOwners[p, default: []].append(c) } }
        byPhone = phoneOwners.compactMapValues { $0.count == 1 ? $0[0] : nil }
        byName = names.sorted { $0.name.count > $1.name.count }
    }

    /// Kleine letters, leestekens weg, rechtsvormen weg; omringd door spaties voor woordgrenzen.
    static func normalize(_ s: String, stripLegalForms: Bool = false) -> String {
        // "M&M" blijft één woord ("menm"), zodat ook een korte naam als "M&M bv" herkend wordt.
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"(?<=[a-z0-9])&(?=[a-z0-9])"#, with: "en", options: .regularExpression)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let kept = stripLegalForms ? words.filter { !legalForms.contains($0) } : words
        return kept.joined(separator: " ")
    }

    static func registrableDomain(_ host: String) -> [String] {
        // "app.janssen.be" → ["app.janssen.be", "janssen.be"]; nooit enkel een publiek achtervoegsel.
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return [host] }
        return (0...(parts.count - 2)).map { parts[$0...].joined(separator: ".") }
            .filter { !publicSuffixes.contains($0) }
    }

    /// Match voor een venster. De reden is kort en leesbaar, bv. "website janssen.be".
    func match(app: String, title: String, host: String) -> (Match, String) {
        let cacheKey = [app, title, host].joined(separator: "\u{1}")
        cacheLock.lock()
        let hit = cache[cacheKey]
        cacheLock.unlock()
        if let hit { return hit }
        let result = compute(app: app, title: title, host: host)
        cacheLock.lock()
        cache[cacheKey] = result
        cacheLock.unlock()
        return result
    }

    /// Je eigen voor- en volledige naam (uit Teamleader) en de naam van deze Mac-gebruiker.
    static var ownNames: [String] {
        var names = UserDefaults.standard.stringArray(forKey: "tlOwnNames") ?? []
        let full = NSFullUserName()
        names.append(full)
        if let first = full.split(separator: " ").first { names.append(String(first)) }
        return names
    }

    /// Haalt de browsernaam en wat erna komt (profielnaam) van een venstertitel:
    /// "TPC Cloud - Google Chrome - Matthias" → "TPC Cloud".
    /// Enkel aan het einde: " - Google Chrome", eventueel gevolgd door " - <profiel>". Een titel als
    /// "Offerte - Architectenbureau Janssen" blijft dus heel.
    static func cleanTitle(_ title: String) -> String {
        let pattern = #"\s[-–—]\s(Google Chrome|Microsoft\x{200B}? ?Edge|Brave|Vivaldi|Opera|Arc|Safari|Mozilla Firefox|Firefox|Chromium)(\s[-–—]\s[^-–—]{1,40})?$"#
        guard let r = title.range(of: pattern, options: .regularExpression) else {
            return title.trimmingCharacters(in: .whitespaces)
        }
        var page = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        // Edge zet het profiel vóór de browsernaam: "Pagina - Profiel - Microsoft Edge".
        if title[r].contains("Edge"),
           let p = page.range(of: #"\s[-–—]\s[^-–—]{1,40}$"#, options: .regularExpression) {
            let profile = page[p].dropFirst(3).trimmingCharacters(in: .whitespaces)
            if isEdgeProfile(profile) {
                page = String(page[..<p.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return page
    }

    /// De profielnamen uit Edge zelf ("Local State"). Lukt dat niet, dan gelden korte namen als profiel.
    private static let edgeProfiles: Set<String>? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Microsoft Edge/Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return nil }
        let names = cache.values.compactMap { ($0 as? [String: Any])?["name"] as? String }
        return names.isEmpty ? nil : Set(names.map { $0.lowercased() })
    }()

    private static func isEdgeProfile(_ s: String) -> Bool {
        let l = s.lowercased()
        if ["personal", "persoonlijk", "work", "werk", "profiel 1", "profile 1"].contains(l) { return true }
        if let known = edgeProfiles { return known.contains(l) }
        return (1...2).contains(l.split(separator: " ").count) && !l.contains(where: { !$0.isLetter && $0 != " " })
    }

    private func compute(app: String, title rawTitle: String, host: String) -> (Match, String) {
        let title = Self.cleanTitle(rawTitle)
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
                if let c = byDomain[d] { return (Match(company: c, invoiceable: defaultInvoiceable), "website \(h)") }
            }
        }
        let normTitle = " " + Self.normalize(title) + " "
        if normTitle.count > 2, let hit = byName.first(where: { normTitle.contains(" \($0.name) ") }) {
            let where_ = title.isEmpty ? app : "‘\(String(title.prefix(40)))’"
            return (Match(company: hit.company, invoiceable: defaultInvoiceable), "\(hit.company.name) in \(where_)")
        }
        return (.unassigned, host.isEmpty ? app : host)
    }

    /// Klant bij een telefoonnummer (nummer van een bedrijf in Teamleader), of bij de bedrijfsnaam die de
    /// telefoonapp toont.
    func match(phone: String, companyHint: String = "") -> (Match, String)? {
        if let key = Phone.key(phone), let c = byPhone[key] {
            return (Match(company: c, invoiceable: defaultInvoiceable), "nummer van \(c.name)")
        }
        let hint = " " + Self.normalize(companyHint) + " "
        if hint.count > 2, let hit = byName.first(where: { hint.contains(" \($0.name) ") }) {
            return (Match(company: hit.company, invoiceable: defaultInvoiceable), "\(hit.company.name) volgens de telefoon")
        }
        return nil
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
            if let c = byDomain[domain] { return (Match(company: c, invoiceable: defaultInvoiceable), "afspraak met \(email)") }
        }
        let normTitle = " " + Self.normalize(event.title) + " "
        if let hit = byName.first(where: { normTitle.contains(" \($0.name) ") }) {
            return (Match(company: hit.company, invoiceable: defaultInvoiceable), "agenda: \(event.title)")
        }
        return nil
    }
}
