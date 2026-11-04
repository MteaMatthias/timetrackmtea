import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Een korte omschrijving voor de klant ("Mailverkeer ‘Recht van opstal’ en telefoongesprek"), op basis van
/// wat je deed. Altijd ingevuld, zodat elke registratie in Teamleader een omschrijving heeft.
enum Describer {
    /// Omschrijving uit de activiteiten van een voorstel (meeste tijd eerst), zonder AI.
    static func describe(_ p: Proposal) -> String {
        describe(activities: p.activities.map(label) + p.pieces.map(\.label))
    }

    static func describe(activities: [String]) -> String {
        var phrases: [String] = []
        for activity in activities {
            let phrase = self.phrase(activity)
            if !phrase.isEmpty, !phrases.contains(where: { $0.hasPrefix(phrase) || phrase.hasPrefix($0) }) {
                phrases.append(phrase)
            }
            if phrases.count == 2 { break }
        }
        guard !phrases.isEmpty else { return "Werk voor de klant" }
        var text = phrases.count == 2 ? "\(phrases[0]) en \(lowerFirst(phrases[1]))" : phrases[0]
        if text.count > 90 { text = String(text.prefix(88)).trimmingCharacters(in: .whitespaces) + "…" }
        return upperFirst(text)
    }

    /// "Mail: Re: Offerte · 2 min" → "Mail: Re: Offerte"
    static func label(_ line: String) -> String {
        guard let r = line.range(of: " · ", options: .backwards) else { return line }
        return String(line[..<r.lowerBound])
    }

    private static let mailApps: Set<String> = ["mail", "microsoft outlook", "outlook", "spark", "airmail", "mimestream", "superhuman"]
    private static let officeApps: Set<String> = ["microsoft word", "microsoft excel", "microsoft powerpoint", "pages",
                                                  "numbers", "keynote", "preview", "voorvertoning", "adobe acrobat",
                                                  "acrobat reader"]
    private static let designApps: Set<String> = ["figma", "adobe photoshop", "adobe illustrator", "adobe indesign",
                                                  "sketch", "canva", "affinity designer"]
    private static let techApps: Set<String> = ["terminal", "iterm2", "xcode", "visual studio code", "code", "cursor",
                                                "sublime text", "transmit", "filezilla", "cyberduck", "sequel ace",
                                                "tableplus", "github desktop", "warp"]
    private static let aiNames = ["claude", "chatgpt", "gemini", "copilot", "perplexity", "mistral"]

    static func phrase(_ label: String) -> String {
        let (app, rest) = split(label)
        let a = app.lowercased()
        switch a {
        case "telefoon":
            return Phone.looksLikeNumber(rest) || rest.isEmpty ? "Telefoongesprek" : "Telefoongesprek met \(rest)"
        case "meeting":
            return rest.isEmpty || rest.lowercased().hasSuffix("-gesprek") ? "Overleg" : "Overleg: \(rest)"
        case "afspraak":
            return rest.isEmpty ? "Afspraak" : rest
        default: break
        }
        if mailApps.contains(a) || ["mail.google.com", "outlook.office.com", "outlook.live.com"].contains(rest.lowercased()) {
            let subject = cleanSubject(rest)
            return subject.isEmpty ? "Mailverkeer" : "Mailverkeer ‘\(subject)’"
        }
        if aiNames.contains(where: { a.contains($0) || rest.lowercased().hasPrefix($0) }) {
            let topic = rest.split(separator: ":", maxSplits: 1).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let generic = topic.isEmpty || aiNames.contains(where: { topic.lowercased().hasPrefix($0) })
                || topic.lowercased().contains("-chat ") || topic.lowercased() == "new chat"
            return generic ? "Uitwerking en analyse" : "Uitwerking ‘\(short(topic))’"
        }
        if officeApps.contains(a) {
            let doc = rest.replacingOccurrences(of: #"\.(docx?|xlsx?|pptx?|pdf|pages|numbers|key)$"#, with: "",
                                                options: [.regularExpression, .caseInsensitive])
            return doc.isEmpty ? "Documentwerk" : "Document ‘\(short(doc))’"
        }
        if designApps.contains(a) { return rest.isEmpty ? "Ontwerpwerk" : "Ontwerp ‘\(short(rest))’" }
        if techApps.contains(a) { return "Technisch werk" }
        if rest.contains("."), !rest.contains(" ") {
            // Een website: bij de klant zelf "Werk aan website", anders opzoekwerk.
            let host = rest.lowercased()
            if host.hasPrefix("docs.google.com") { return "Documentwerk" }
            if host.contains("youtube.") || host.contains("vimeo.") { return "Opzoekwerk" }
            return Matcher.isGeneric(host) ? "Opzoekwerk" : "Werk aan \(host)"
        }
        if a.isEmpty || a == "pauze" { return "" }
        return rest.isEmpty ? "Werk in \(app)" : "\(app): \(short(rest))"
    }

    private static func split(_ label: String) -> (String, String) {
        guard let r = label.range(of: ": ") else { return (label, "") }
        return (String(label[..<r.lowerBound]), String(label[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    private static func cleanSubject(_ s: String) -> String {
        var text = s
        while let r = text.range(of: #"^(re|fw|fwd|tr|antw|doorst|aw|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(r)
        }
        let l = text.lowercased()
        if l.contains("inkomende") || l.contains("inbox") || l.contains("postvak") || l.contains("ongelezen")
            || l.contains("berichten") { return "" }
        return short(text.trimmingCharacters(in: .whitespaces))
    }

    private static func short(_ s: String) -> String {
        s.count > 45 ? String(s.prefix(43)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    private static func upperFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    private static func lowerFirst(_ s: String) -> String {
        // "Werk aan janssen.be" → "werk aan janssen.be", maar een naam of afkorting blijft zoals ze is.
        guard let first = s.first, first.isUppercase, s.dropFirst().first?.isLowercase ?? false else { return s }
        return first.lowercased() + s.dropFirst()
    }
}

/// Schaaft de omschrijving bij met het taalmodel op de Mac zelf (Apple Intelligence, macOS 26+).
/// Er gaat niets naar buiten; zonder Apple Intelligence blijft de omschrijving zonder AI staan.
enum AIDescriber {
    private static var cache: [String: String] = [:]

    @MainActor
    static func improve(_ p: Proposal) async -> String? {
        let key = p.match.companyName + "|" + p.activities.joined(separator: "|")
        if let hit = cache[key] { return hit }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: """
                Je schrijft omschrijvingen voor tijdsregistraties die een klant op zijn factuur ziet. \
                Schrijf in het Nederlands, zakelijk en kort: 3 tot 8 woorden, geen punt op het einde, \
                geen aanhalingstekens, geen namen van programma's of AI-tools, geen tijden of duur.
                """)
            let prompt = """
                Klant: \(p.match.companyName.isEmpty ? "onbekend" : p.match.companyName)
                Wat er gebeurde (meeste tijd eerst):
                \(p.activities.prefix(5).map { "- " + Describer.label($0) }.joined(separator: "\n"))
                Voorstel zonder AI: \(Describer.describe(p))
                Geef enkel de omschrijving.
                """
            guard let response = try? await session.respond(to: prompt) else { return nil }
            var text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’."))
            if let line = text.split(separator: "\n").first { text = String(line) }
            guard (3...90).contains(text.count) else { return nil }
            cache[key] = text
            return text
        }
        #endif
        return nil
    }
}
