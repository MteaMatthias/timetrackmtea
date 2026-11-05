import AppKit
import ApplicationServices

/// Leest uit de Claude- en ChatGPT-app waarover het gesprek gaat. Die apps tonen enkel "Claude" als
/// venstertitel; de titel van het gesprek staat bovenaan in de webinhoud. Komt er in het gesprek een klantnaam
/// voor die niet in de titel staat, dan wordt die erbij gezet ("Nieuwsbrief november — Janssen NV"), zodat
/// het voorstel de juiste klant krijgt. Alles blijft op de Mac; er wordt niets van het gesprek bewaard
/// behalve die titel.
enum AIChatReader {
    private static let lock = NSLock()
    private static var enabled = Set<pid_t>()
    private static var cache: [String: (title: String?, at: Date)] = [:]

    static let assistantApps: Set<String> = ["Claude", "ChatGPT", "Perplexity", "Gemini", "Copilot", "Mistral", "Le Chat"]

    /// Vraagt een Electron-app om zijn webinhoud te tonen aan de Accessibility-API.
    static func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        lock.lock()
        let first = enabled.insert(pid).inserted
        lock.unlock()
        if first { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
    }

    /// Titel van het gesprek (eventueel met de klant uit de inhoud), of nil als het geen AI-chat is of er niets
    /// bruikbaars te vinden is. Per gesprek hoogstens één keer per 30 s opnieuw gelezen.
    static func title(app: String, web: Tracker.WebArea) -> String? {
        // De app-laag zelf (file://…/app.asar) bevat het gesprek niet.
        if web.url?.isFileURL == true { return nil }
        let host = web.url?.host?.lowercased() ?? ""
        guard assistantApps.contains(app) || Planner.assistantHosts.contains(host) && !host.contains("youtube") else {
            return nil
        }
        let key = app + "|" + (web.url?.absoluteString ?? "")
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < 30 { return cached.title }

        let texts = collect(web.element)
        var title = web.title.map { Planner.chatTitle($0, app: app) } ?? ""
        if title.isEmpty { title = headerTitle(texts) ?? "" }
        if title.isEmpty, let url = web.url, let id = Tracker.chatName(url) { title = id }
        var result: String? = title.isEmpty ? nil : title
        // Een klantnaam in het gesprek (niet in de titel): erbij zetten zodat het voorstel de klant kent.
        if let base = result {
            let content = texts.prefix(120).map(\.text).joined(separator: " \u{2022} ")
            let (match, _) = Matcher.current().match(app: "", title: String(content.prefix(4000)), host: "")
            if match.isAssigned, !match.companyName.isEmpty,
               !Matcher.normalize(base).contains(Matcher.normalize(match.companyName, stripLegalForms: true)) {
                result = "\(base) — \(match.companyName)"
            }
        }
        lock.lock()
        cache[key] = (result, Date())
        if cache.count > 200 { cache.removeAll() }
        lock.unlock()
        return result
    }

    struct Text { let text: String; let role: String; let frame: CGRect }

    /// Teksten in de webinhoud (beperkt in aantal en diepte), met hun plaats op het scherm.
    static func collect(_ root: AXUIElement, limit: Int = 700) -> [Text] {
        var out: [Text] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            var text = ""
            switch role {
            case "AXStaticText": text = string(element, kAXValueAttribute) ?? ""
            case "AXButton", "AXHeading", "AXLink", "AXTextField":
                text = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
                    ?? string(element, kAXValueAttribute) ?? ""
            default: break
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(Text(text: trimmed, role: role, frame: frame(element))) }
            guard depth < 30 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.prefix(60).map { ($0, depth + 1) })
            }
        }
        return out
    }

    private static let ignored: Set<String> = [
        "claude", "chatgpt", "new chat", "nieuwe chat", "share", "delen", "chats", "projects", "projecten",
        "artifacts", "recents", "recent", "starred", "settings", "instellingen", "upgrade", "help", "search",
        "zoeken", "menu", "sidebar", "open sidebar", "close sidebar", "copy", "kopiëren", "retry", "edit",
        "opus", "sonnet", "haiku", "fable", "gpt-4o", "gpt-5", "temporary chat", "library", "explore gpts",
    ]

    /// De gesprekstitel staat bovenaan het gesprek (rechts van de zijbalk): de eerste knop of tekst daar die
    /// geen vaste knop van de app is.
    static func headerTitle(_ texts: [Text]) -> String? {
        let framed = texts.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        guard let top = framed.map(\.frame.minY).min(),
              let left = framed.map(\.frame.minX).min(),
              let right = framed.map(\.frame.maxX).max() else { return nil }
        let width = right - left
        let candidates = framed.filter { t in
            let lower = t.text.lowercased()
            return t.frame.minY - top < 70
                && t.frame.minX > left + width * 0.18
                && (3...100).contains(t.text.count)
                && !ignored.contains(lower)
                && !ignored.contains(where: { lower.hasPrefix($0 + " ") && t.text.count < 25 })
                && ["AXButton", "AXHeading", "AXStaticText"].contains(t.role)
        }
        return candidates.sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
            .first?.text
    }

    /// Voor de diagnose in Instellingen: wat TimeTrack leest in de Claude-app (of ChatGPT), ook als die niet
    /// vooraan staat; anders in het voorste programma.
    static func diagnose() async -> String {
        let running = NSWorkspace.shared.runningApplications
        let own = Bundle.main.bundleIdentifier
        let app = running.first { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }
            ?? running.first { $0.bundleIdentifier == "com.openai.chat" }
            ?? NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == own ? nil : $0 }
        guard let app else { return "Claude is niet geopend." }
        let name = app.localizedName ?? "?"
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        enableWebAccessibility(element, pid: app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = mainWindow(element) else {
            return "\(name): geen venster leesbaar. Staat TimeTrack aan in Privacy en beveiliging → Toegankelijkheid?"
        }
        var areas: [Tracker.WebArea] = []
        var texts: [Text] = []
        var web: Tracker.WebArea?
        // Chromium bouwt de toegankelijkheidsboom pas op na de eerste vraag: tot 3 keer proberen.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            areas = Tracker.webAreas(window)
            web = areas.first { ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") } ?? areas.last
            texts = web.map { collect($0.element) } ?? []
            if !texts.isEmpty { break }
        }
        lock.lock(); cache.removeAll(); lock.unlock()
        let found = web.flatMap { title(app: name, web: $0) } ?? "–"
        let top = texts.prefix(25).map { "• \($0.role.replacingOccurrences(of: "AX", with: "")): \($0.text.prefix(60))" }
        let layers = areas.map { "• \($0.url?.absoluteString.prefix(70) ?? "–") · \($0.title ?? "–")" }
        return """
            Programma: \(name)
            Gevonden gesprek: \(found)
            Webinhoud (\(areas.count) lagen):
            \(layers.isEmpty ? "• geen" : layers.joined(separator: "\n"))
            Teksten bovenaan (\(texts.count) gelezen):
            \(top.joined(separator: "\n"))
            """
    }

    private static func mainWindow(_ app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            return list.first
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        value = nil
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}
