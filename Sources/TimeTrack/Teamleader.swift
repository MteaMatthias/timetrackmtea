import AppKit
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
    case auth(String)
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Vul eerst Client ID en Client secret in."
        case .notConnected: return "Niet verbonden met Teamleader."
        case .auth(let msg): return "Aanmelden bij Teamleader mislukt: \(msg)"
        case .api(let status, let msg): return "Teamleader-fout \(status): \(msg)"
        }
    }
}

/// Koppeling met de Teamleader Focus API (OAuth 2 + JSON-RPC-achtige endpoints).
@MainActor
final class Teamleader: ObservableObject {
    static let shared = Teamleader()
    static let port: UInt16 = 53682
    static let redirectURI = "http://127.0.0.1:53682/callback"
    private static let authURL = "https://focus.teamleader.eu/oauth2/authorize"
    private static let tokenURL = "https://focus.teamleader.eu/oauth2/access_token"
    private static let apiBase = "https://api.focus.teamleader.eu/"

    @Published private(set) var userName: String? = UserDefaults.standard.string(forKey: "tlUserName")
    @Published private(set) var workTypes: [TLItem] = Teamleader.loadCachedWorkTypes()

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private var refreshTask: Task<Void, Error>?

    private init() {
        if isConnected {
            Task { try? await self.refreshProfile() }
        }
    }

    var isConnected: Bool { tokens != nil }

    var clientId: String {
        get { UserDefaults.standard.string(forKey: "tlClientId") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "tlClientId") }
    }

    var clientSecret: String {
        get { Keychain.string("clientSecret") ?? "" }
        set { Keychain.set("clientSecret", newValue.trimmingCharacters(in: .whitespaces)) }
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

    // MARK: Verbinden

    func connect() async throws {
        guard !clientId.isEmpty, !clientSecret.isEmpty else { throw TLError.notConfigured }
        let state = UUID().uuidString
        var url = URLComponents(string: Self.authURL)!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        ]
        let receiver = try OAuthReceiver(port: Self.port)
        NSWorkspace.shared.open(url.url!)
        let code = try await receiver.waitForCode(state: state)
        try await requestToken(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI])
        try await refreshProfile()
    }

    func disconnect() {
        tokens = nil
        userName = nil
        UserDefaults.standard.removeObject(forKey: "tlUserName")
    }

    func refreshProfile() async throws {
        let me = try await call("users.me")
        if let d = me["data"] as? [String: Any] {
            let name = "\(d["first_name"] as? String ?? "") \(d["last_name"] as? String ?? "")"
                .trimmingCharacters(in: .whitespaces)
            userName = name.isEmpty ? (d["email"] as? String ?? "Teamleader") : name
            UserDefaults.standard.set(userName, forKey: "tlUserName")
        }
        workTypes = try await list("workTypes.list", ["page": ["size": 100, "number": 1]])
        UserDefaults.standard.set(try? JSONEncoder().encode(workTypes), forKey: "tlWorkTypes")
    }

    nonisolated private static func loadCachedWorkTypes() -> [TLItem] {
        guard let data = UserDefaults.standard.data(forKey: "tlWorkTypes") else { return [] }
        return (try? JSONDecoder().decode([TLItem].self, from: data)) ?? []
    }

    // MARK: Endpoints

    func searchCompanies(_ term: String) async throws -> [TLItem] {
        try await list("companies.list", ["filter": ["term": term, "status": "active"],
                                          "page": ["size": 25, "number": 1]])
    }

    /// Stuurt een registratie naar Teamleader en geeft het id van de tijdsregistratie terug.
    func addTime(_ e: Entry) async throws -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var body: [String: Any] = [
            "started_at": iso.string(from: e.startDate),
            "duration": e.minutes * 60,
            "description": e.description,
            "invoiceable": e.invoiceable,
        ]
        if let company = e.companyId { body["subject"] = ["type": "company", "id": company] }
        if let workType = e.workTypeId { body["work_type_id"] = workType }
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
        if current.expires < Date() { try await refresh() }
        var (data, status) = try await post(endpoint, body)
        if status == 401 {
            try await refresh()
            (data, status) = try await post(endpoint, body)
        }
        guard (200..<300).contains(status) else { throw TLError.api(status, Self.errorMessage(data)) }
        guard !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func post(_ endpoint: String, _ body: [String: Any]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: Self.apiBase + endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(tokens?.access ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Refresh tokens zijn maar één keer bruikbaar: gelijktijdige vernieuwingen worden samengevoegd.
    private func refresh() async throws {
        if let running = refreshTask { return try await running.value }
        guard let refreshToken = tokens?.refresh else { throw TLError.notConnected }
        let task = Task { try await self.requestToken(["grant_type": "refresh_token", "refresh_token": refreshToken]) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            try await task.value
        } catch TLError.auth(let msg) {
            disconnect()
            throw TLError.auth(msg)
        }
    }

    private func requestToken(_ params: [String: String]) async throws {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = params
        body["client_id"] = clientId
        body["client_secret"] = clientSecret
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String
        else { throw TLError.auth(Self.errorMessage(data)) }
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        tokens = Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(lifetime - 60))
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

// MARK: - OAuth-redirect opvangen op 127.0.0.1

/// Mini-webserver die één OAuth-redirect opvangt en de autorisatiecode teruggeeft.
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

    static func data(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(_ key: String) -> String? {
        data(key).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ key: String, _ value: Data?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = value
        SecItemAdd(add as CFDictionary, nil)
    }

    static func set(_ key: String, _ value: String) {
        set(key, value.isEmpty ? nil : Data(value.utf8))
    }
}
