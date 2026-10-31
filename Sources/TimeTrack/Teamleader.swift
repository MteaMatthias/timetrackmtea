import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct TLItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

enum TLError: LocalizedError {
    case notConfigured
    case notConnected
    case invalidGrant
    case auth(String)
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Vul eerst Client ID en Client secret in."
        case .notConnected: return "Niet verbonden met Teamleader."
        case .invalidGrant: return "De koppeling met Teamleader is verlopen. Verbind opnieuw via Instellingen."
        case .auth(let msg): return "Verbinden met Teamleader mislukt: \(msg)"
        case .api(let status, let msg): return "Teamleader-fout \(status): \(msg)"
        }
    }
}

/// Koppeling met de Teamleader Focus API.
///
/// Standaard verloopt het aanmelden via tools.mtea.be: dat portaal kent het client secret van de MTEA-integratie,
/// wisselt de code in en geeft de tokens eenmalig door aan de app (via timetrack://callback). Vernieuwen gaat ook
/// via het portaal. Wie een eigen integratie gebruikt, kan in Instellingen een eigen Client ID/secret opgeven.
@MainActor
final class Teamleader: ObservableObject {
    static let shared = Teamleader()
    static let urlScheme = "timetrack"
    static let customPort: UInt16 = 53682
    static let customRedirectURI = "http://127.0.0.1:53682/callback"
    static let defaultPortal = "https://tools.mtea.be"
    private static let authURL = "https://focus.teamleader.eu/oauth2/authorize"
    private static let tokenURL = "https://focus.teamleader.eu/oauth2/access_token"
    private static let apiBase = "https://api.focus.teamleader.eu/"

    @Published private(set) var userName: String? = UserDefaults.standard.string(forKey: "tlUserName")
    @Published private(set) var workTypes: [TLItem] = Teamleader.loadCachedWorkTypes()
    @Published private(set) var companyCount = 0

    private var userId: String? {
        get { UserDefaults.standard.string(forKey: "tlUserId") }
        set { UserDefaults.standard.set(newValue, forKey: "tlUserId") }
    }

    /// Standaardwaarde "factureerbaar" uit de voorkeuren van de gebruiker in Teamleader.
    var defaultInvoiceable: Bool { UserDefaults.standard.object(forKey: "tlInvoiceable") as? Bool ?? true }
    /// Teamleader weigert registraties die verder teruggaan dan dit aantal uur (nil = geen limiet).
    var historicLimitHours: Double? { UserDefaults.standard.object(forKey: "tlHistoricLimit") as? Double }

    var portalURL: String {
        get { UserDefaults.standard.string(forKey: "portalURL") ?? Self.defaultPortal }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: CharacterSet(charactersIn: " /")), forKey: "portalURL") }
    }

    var useCustomClient: Bool {
        get { UserDefaults.standard.bool(forKey: "useCustomClient") }
        set { UserDefaults.standard.set(newValue, forKey: "useCustomClient"); objectWillChange.send() }
    }

    var clientId: String {
        get { UserDefaults.standard.string(forKey: "tlClientId") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "tlClientId") }
    }

    var clientSecret: String {
        get { Keychain.string("clientSecret") ?? "" }
        set { Keychain.set("clientSecret", newValue.trimmingCharacters(in: .whitespaces)) }
    }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private lazy var storedTokens: Tokens? =
        Keychain.data("tokens").flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }

    private var tokens: Tokens? {
        get { storedTokens }
        set {
            objectWillChange.send()
            storedTokens = newValue
            Keychain.set("tokens", newValue.flatMap { try? JSONEncoder().encode($0) })
        }
    }

    var isConnected: Bool { tokens != nil }

    private var refreshTask: Task<Void, Error>?
    private var pendingCallback: CheckedContinuation<URL, Error>?
    private var callbackGeneration = 0
    private var receiver: OAuthReceiver?

    private init() {
        companyCount = Store.companies().count
        if isConnected {
            Task {
                try? await self.refreshProfile()
                try? await self.syncCompanies(force: false)
            }
        }
    }

    // MARK: Verbinden

    func connect() async throws {
        if useCustomClient {
            try await connectWithOwnClient()
        } else {
            try await connectViaPortal()
        }
        try await refreshProfile()
        try await syncCompanies(force: true)
    }

    private func connectViaPortal() async throws {
        let state = UUID().uuidString
        // Zoals PKCE: enkel deze app kent de verifier, dus enkel zij kan het ticket inwisselen
        // (ook als een ander programma timetrack:// zou onderscheppen).
        let verifier = Self.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard var url = URLComponents(string: portalURL + "/timetrack/koppel") else {
            throw TLError.auth("ongeldig portaaladres")
        }
        url.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "challenge", value: challenge)]
        NSWorkspace.shared.open(url.url!)

        let callback = try await waitForCallback()
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw TLError.auth("onverwacht antwoord (state)") }
        if let error = value("error") { throw TLError.auth(error) }
        guard let ticket = value("ticket") else { throw TLError.auth("geen ticket ontvangen") }
        try storeTokens(try await portalPost("/api/timetrack/token", ["ticket": ticket, "verifier": verifier]))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func connectWithOwnClient() async throws {
        guard !clientId.isEmpty, !clientSecret.isEmpty else { throw TLError.notConfigured }
        let state = UUID().uuidString
        var url = URLComponents(string: Self.authURL)!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: Self.customRedirectURI),
        ]
        let receiver = try OAuthReceiver(port: Self.customPort)
        self.receiver = receiver
        defer { self.receiver = nil }
        NSWorkspace.shared.open(url.url!)
        let code = try await receiver.waitForCode(state: state)
        try storeTokens(try await tokenEndpoint([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.customRedirectURI,
        ]))
    }

    /// Opgeroepen door de AppDelegate wanneer de browser timetrack://callback?... opent.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == Self.urlScheme, let cont = pendingCallback else { return }
        pendingCallback = nil
        cont.resume(returning: url)
    }

    func cancelConnect() {
        receiver?.cancel()
        if let cont = pendingCallback {
            pendingCallback = nil
            cont.resume(throwing: CancellationError())
        }
    }

    private func waitForCallback() async throws -> URL {
        callbackGeneration += 1
        let generation = callbackGeneration
        return try await withCheckedThrowingContinuation { cont in
            pendingCallback?.resume(throwing: CancellationError())
            pendingCallback = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard let self, self.callbackGeneration == generation, let pending = self.pendingCallback else { return }
                self.pendingCallback = nil
                pending.resume(throwing: TLError.auth("geen antwoord binnen 5 minuten"))
            }
        }
    }

    func disconnect() {
        tokens = nil
        userName = nil
        userId = nil
        UserDefaults.standard.removeObject(forKey: "tlUserName")
    }

    // MARK: Gegevens

    func refreshProfile() async throws {
        let me = try await call("users.me")
        if let d = me["data"] as? [String: Any] {
            let name = "\(d["first_name"] as? String ?? "") \(d["last_name"] as? String ?? "")"
                .trimmingCharacters(in: .whitespaces)
            userName = name.isEmpty ? (d["email"] as? String ?? "Teamleader") : name
            userId = d["id"] as? String
            UserDefaults.standard.set(userName, forKey: "tlUserName")
            if let email = d["email"] as? String, let domain = email.split(separator: "@").last {
                UserDefaults.standard.set(String(domain).lowercased(), forKey: "tlOwnDomain")
            }
            let prefs = d["preferences"] as? [String: Any]
            if let invoiceable = prefs?["invoiceable"] as? Bool {
                UserDefaults.standard.set(invoiceable, forKey: "tlInvoiceable")
            }
            if let limit = prefs?["historic_time_tracking_limit"] as? [String: Any], let value = limit["value"] as? Double {
                UserDefaults.standard.set(value, forKey: "tlHistoricLimit")
            } else {
                UserDefaults.standard.removeObject(forKey: "tlHistoricLimit")
            }
        }
        var types: [TLItem] = []
        for page in 1...10 {
            let batch = try await list("workTypes.list", ["page": ["size": 100, "number": page]])
            types += batch
            if batch.count < 100 { break }
        }
        workTypes = types
        UserDefaults.standard.set(try? JSONEncoder().encode(types), forKey: "tlWorkTypes")
    }

    nonisolated private static func loadCachedWorkTypes() -> [TLItem] {
        guard let data = UserDefaults.standard.data(forKey: "tlWorkTypes") else { return [] }
        return (try? JSONDecoder().decode([TLItem].self, from: data)) ?? []
    }

    /// Haalt alle actieve bedrijven op (naam, website, e-maildomeinen) voor de automatische herkenning.
    func syncCompanies(force: Bool) async throws {
        let last = UserDefaults.standard.double(forKey: "tlCompaniesSynced")
        guard force || Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        var companies: [Company] = []
        for page in 1...200 {
            let result = try await call("companies.list", ["filter": ["status": "active"],
                                                           "page": ["size": 100, "number": page]])
            let data = result["data"] as? [[String: Any]] ?? []
            for c in data {
                guard let id = c["id"] as? String, let name = c["name"] as? String else { continue }
                var domains = Set<String>()
                if let site = c["website"] as? String, !site.isEmpty {
                    let withScheme = site.contains("://") ? site : "https://" + site
                    if var host = URL(string: withScheme)?.host?.lowercased() {
                        if host.hasPrefix("www.") { host.removeFirst(4) }
                        domains.insert(host)
                    }
                }
                for e in c["emails"] as? [[String: Any]] ?? [] {
                    if let email = e["email"] as? String, let d = email.split(separator: "@").last {
                        domains.insert(String(d).lowercased())
                    }
                }
                companies.append(Company(id: id, name: name, domains: domains.sorted()))
            }
            if data.count < 100 { break }
        }
        Store.replaceCompanies(companies)
        companyCount = companies.count
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "tlCompaniesSynced")
    }

    /// Zoekt eerst in de lokale lijst; enkel als die leeg is in Teamleader zelf.
    func searchCompanies(_ term: String) async throws -> [TLItem] {
        let local = Store.companies()
        if !local.isEmpty {
            let q = term.lowercased()
            return local.filter { $0.name.lowercased().contains(q) || $0.domains.contains { $0.contains(q) } }
                .sorted { $0.name.count < $1.name.count }
                .prefix(25).map { TLItem(id: $0.id, name: $0.name) }
        }
        return try await list("companies.list", ["filter": ["term": term, "status": "active"],
                                                 "page": ["size": 25, "number": 1]])
    }

    /// Tijdsregistraties van de aangemelde gebruiker die starten in [from, to).
    func registered(from: Double, to: Double) async throws -> [Registered] {
        let iso = ISO8601DateFormatter()
        var filter: [String: Any] = [
            "started_after": iso.string(from: Date(timeIntervalSince1970: from - 86400)),
            "started_before": iso.string(from: Date(timeIntervalSince1970: to)),
        ]
        if let userId { filter["user_id"] = userId }
        var out: [Registered] = []
        for page in 1...20 {
            let result = try await call("timeTracking.list", ["filter": filter, "page": ["size": 100, "number": page]])
            let data = result["data"] as? [[String: Any]] ?? []
            for item in data {
                guard let id = item["id"] as? String else { continue }
                let duration = (item["duration"] as? Double) ?? 0
                let start = (item["started_at"] as? String).flatMap { iso.date(from: $0)?.timeIntervalSince1970 }
                // Registraties zonder tijdstip (enkel duur) horen bij hun dag.
                let dayStart = (item["started_on"] as? String).flatMap { Self.dayDate($0)?.timeIntervalSince1970 }
                guard let anchor = start ?? dayStart, anchor >= from, anchor < to else { continue }
                let subject = item["subject"] as? [String: Any]
                let companyId = subject?["type"] as? String == "company" ? subject?["id"] as? String : nil
                out.append(Registered(
                    id: id, start: start, duration: duration, companyId: companyId,
                    companyName: companyId.flatMap(Store.companyName(id:)) ?? Self.subjectLabel(subject?["type"] as? String),
                    description: item["description"] as? String ?? "",
                    day: item["started_on"] as? String))
            }
            if data.count < 100 { break }
        }
        return out
    }

    private static func subjectLabel(_ type: String?) -> String {
        switch type {
        case "contact": return "Contact"
        case "milestone": return "Project"
        case "ticket": return "Ticket"
        case "todo", "event": return "Taak/afspraak"
        default: return "Zonder klant"
        }
    }

    private static func dayDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Maakt een tijdsregistratie aan en geeft het id terug.
    func addTime(start: Double, end: Double, match: Match, description: String, invoiceable: Bool) async throws -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var body: [String: Any] = [
            "started_at": iso.string(from: Date(timeIntervalSince1970: start)),
            "duration": Int((end - start).rounded()),
            "description": description,
            "invoiceable": invoiceable,
        ]
        if let company = match.companyId { body["subject"] = ["type": "company", "id": company] }
        if let workType = match.workTypeId { body["work_type_id"] = workType }
        let result = try await call("timeTracking.add", body)
        return (result["data"] as? [String: Any])?["id"] as? String ?? "ok"
    }

    private func list(_ endpoint: String, _ body: [String: Any]) async throws -> [TLItem] {
        let result = try await call(endpoint, body)
        return (result["data"] as? [[String: Any]] ?? []).compactMap { item -> TLItem? in
            guard let id = item["id"] as? String else { return nil }
            return TLItem(id: id, name: item["name"] as? String ?? id)
        }
    }

    // MARK: HTTP

    func call(_ endpoint: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        guard let current = tokens else { throw TLError.notConnected }
        if current.expires < Date() { try await refreshTokens() }
        var refreshed = false
        for attempt in 1...4 {
            let (data, response) = try await post(endpoint, body)
            switch response.statusCode {
            case 200..<300:
                guard !data.isEmpty else { return [:] }
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            case 401 where !refreshed:
                try await refreshTokens()
                refreshed = true
            case 429 where attempt < 4:
                // Teamleader laat ongeveer 200 calls per minuut toe.
                let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 2), 60) * 1_000_000_000))
            default:
                throw TLError.api(response.statusCode, Self.errorMessage(data))
            }
        }
        throw TLError.api(429, "Te veel aanvragen, probeer het zo dadelijk opnieuw.")
    }

    private func post(_ endpoint: String, _ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: Self.apiBase + endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(tokens?.access ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, response as? HTTPURLResponse ?? HTTPURLResponse())
    }

    /// Refresh tokens zijn maar één keer bruikbaar: gelijktijdige vernieuwingen worden samengevoegd.
    private func refreshTokens() async throws {
        if let running = refreshTask { return try await running.value }
        guard let refreshToken = tokens?.refresh else { throw TLError.notConnected }
        let task = Task { () throws -> Void in
            let json = self.useCustomClient
                ? try await self.tokenEndpoint(["grant_type": "refresh_token", "refresh_token": refreshToken])
                : try await self.portalPost("/api/timetrack/refresh", ["refresh_token": refreshToken])
            try self.storeTokens(json)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            try await task.value
        } catch TLError.invalidGrant {
            // Enkel een echt ongeldig refresh token koppelt los; een tijdelijke storing niet.
            disconnect()
            throw TLError.invalidGrant
        }
    }

    private func storeTokens(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw TLError.auth("geen tokens ontvangen")
        }
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        tokens = Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(lifetime - 60))
    }

    /// Token-endpoint van Teamleader (enkel bij een eigen integratie).
    private func tokenEndpoint(_ params: [String: String]) async throws -> [String: Any] {
        var body = params
        body["client_id"] = clientId
        body["client_secret"] = clientSecret
        return try await postJSON(URL(string: Self.tokenURL)!, body)
    }

    /// Endpoints van het portaal (tools.mtea.be) die het client secret toevoegen.
    private func portalPost(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: portalURL + path) else { throw TLError.auth("ongeldig portaaladres") }
        return try await postJSON(url, body)
    }

    private func postJSON(_ url: URL, _ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Ruimer dan de time-out van het portaal naar Teamleader (20 s), zodat een vernieuwd token niet verloren gaat.
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 200 { return json }
        let message = Self.errorMessage(data)
        if [400, 401, 410].contains(status), (json["error"] as? String) == "invalid_grant" || message.contains("invalid_grant") {
            throw TLError.invalidGrant
        }
        throw TLError.api(status, message)
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errors = json["errors"] as? [[String: Any]] {
                let titles = errors.compactMap { ($0["detail"] as? String) ?? ($0["title"] as? String) }
                if !titles.isEmpty { return titles.joined(separator: "; ") }
            }
            if let msg = (json["error_description"] ?? json["message"] ?? json["error"]) as? String { return msg }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

// MARK: - OAuth-redirect opvangen op 127.0.0.1 (enkel bij een eigen integratie)

@MainActor
final class OAuthReceiver {
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, Error>?

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func waitForCode(state: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn, state: state) }
            }
            listener.stateUpdateHandler = { [weak self] newState in
                if case .failed(let error) = newState {
                    Task { @MainActor in self?.finish(.failure(error)) }
                }
            }
            listener.start(queue: .main)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                self?.finish(.failure(TLError.auth("geen antwoord binnen 5 minuten")))
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        listener.cancel()
        cont.resume(with: result)
    }

    private func handle(_ conn: NWConnection, state: String) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            Task { @MainActor [weak self] in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
                func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

                var message = "Je kunt dit venster sluiten."
                if target.hasPrefix("/callback") {
                    if let code = value("code"), value("state") == state {
                        message = "TimeTrack is verbonden met Teamleader. Je kunt dit venster sluiten."
                        self?.finish(.success(code))
                    } else {
                        let reason = value("error") ?? "ongeldig antwoord"
                        message = "Verbinden mislukt: \(reason)"
                        self?.finish(.failure(TLError.auth(reason)))
                    }
                }
                let safe = message.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                let html = Data("""
                    <!doctype html><meta charset="utf-8"><title>TimeTrack</title>
                    <body style="font:16px -apple-system,sans-serif;padding:48px"><h2>TimeTrack</h2><p>\(safe)</p>
                    """.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                    "Content-Length: \(html.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + html, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "be.mtea.timetrack"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func data(_ key: String) -> Data? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(_ key: String) -> String? {
        data(key).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ key: String, _ value: Data?) {
        guard let value else {
            SecItemDelete(base(key) as CFDictionary)
            return
        }
        let update = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = value
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess { NSLog("Keychain: bewaren van %@ mislukt (%d)", key, status) }
        } else if update != errSecSuccess {
            NSLog("Keychain: bijwerken van %@ mislukt (%d)", key, update)
        }
    }

    static func set(_ key: String, _ value: String) {
        set(key, value.isEmpty ? nil : Data(value.utf8))
    }
}
