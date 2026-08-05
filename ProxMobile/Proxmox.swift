import Foundation
import Security

struct ProxmoxResource: Decodable, Identifiable {
    let id: String
    let type: String
    let node: String?
    let name: String?
    let status: String?
    let vmid: Int?
    let cpu: Double?
    let maxcpu: Double?
    let mem: Double?
    let maxmem: Double?
    let uptime: Double?
    let disk: Double?
    let maxdisk: Double?
    let netin: Double?
    let netout: Double?
    let storage: String?
    let tags: String?
    let template: Int?

    var title: String { name ?? storage ?? node ?? id }
    var subtitle: String {
        if let vmid { return "\(type.uppercased()) \(vmid)" }
        return type.capitalized
    }

    var cpuText: String {
        (cpu ?? 0).formatted(.percent.precision(.fractionLength(0)))
    }

    var memoryText: String {
        guard let mem, let maxmem, maxmem > 0 else { return "—" }
        return (mem / maxmem).formatted(.percent.precision(.fractionLength(0)))
    }

    var diskText: String {
        guard let disk, let maxdisk, maxdisk > 0 else { return "—" }
        return (disk / maxdisk).formatted(.percent.precision(.fractionLength(0)))
    }

    var isRunning: Bool { status == "running" || status == "online" }
    var isGuest: Bool { type == "qemu" || type == "lxc" }
    var icon: String {
        switch type {
        case "node": "server.rack"
        case "qemu": "desktopcomputer"
        case "lxc": "shippingbox"
        case "storage": "externaldrive"
        default: "square.stack.3d.up"
        }
    }
}

private struct ProxmoxResponse<T: Decodable>: Decodable { let data: T }
private struct ProxmoxTicket: Decodable {
    let ticket: String
    let CSRFPreventionToken: String?
}

struct ProxmoxTask: Decodable, Identifiable {
    let upid: String
    let node: String
    let type: String
    let status: String?
    let user: String?
    let starttime: Double?
    let endtime: Double?

    var id: String { upid }
    var isRunning: Bool { endtime == nil }
    var result: String { isRunning ? "Running" : (status ?? "Unknown") }
    var started: Date? { starttime.map(Date.init(timeIntervalSince1970:)) }
    var finished: Date? { endtime.map(Date.init(timeIntervalSince1970:)) }
    var title: String {
        let names = [
            "qmstart": "Start virtual machine", "qmstop": "Stop virtual machine",
            "qmshutdown": "Shut down virtual machine", "qmreboot": "Restart virtual machine",
            "vzstart": "Start container", "vzstop": "Stop container",
            "vzshutdown": "Shut down container", "vzreboot": "Restart container",
            "vzdump": "Backup", "qmigrate": "Migrate virtual machine",
            "vzmigrate": "Migrate container", "qmclone": "Clone virtual machine",
            "vzclone": "Clone container", "qmdestroy": "Delete virtual machine",
            "vzdestroy": "Delete container", "qmcreate": "Create virtual machine",
            "vzcreate": "Create container", "qmconfig": "Update virtual machine",
            "vzconfig": "Update container", "qmsnapshot": "Create virtual machine snapshot",
            "vzsnapshot": "Create container snapshot", "qmrollback": "Restore virtual machine snapshot",
            "vzrollback": "Restore container snapshot", "download": "Download",
            "imgdownload": "Download disk image", "aptupdate": "Refresh package information",
            "startall": "Start all guests", "stopall": "Stop all guests",
            "vncproxy": "Open console", "vncshell": "Open node console",
            "termproxy": "Open terminal", "spiceproxy": "Open SPICE console"
        ]
        return names[type] ?? type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct ProxmoxSnapshot {
    let nodes: [ProxmoxResource]
    let guests: [ProxmoxResource]
    let storages: [ProxmoxResource]
    let tasks: [ProxmoxTask]
}

struct ProxmoxWebSession {
    let url: URL
    let cookie: HTTPCookie?
}

struct APISchemaNode: Decodable, Identifiable {
    let path: String
    let text: String
    let leaf: Int?
    let children: [APISchemaNode]?
    let info: [String: APIMethodSchema]?
    var id: String { path }
}

struct APIMethodSchema: Decodable {
    let description: String?
    let method: String?
    let name: String?
    let parameters: APIParametersSchema?
    let permissions: APIPermissionsSchema?
    let protected: Int?
}

struct APIParametersSchema: Decodable {
    let properties: [String: APIParameterSchema]?
}

struct APIParameterSchema: Decodable {
    let type: String?
    let description: String?
    let typetext: String?
    let format: JSONValue?
    let pattern: String?
    let optional: JSONValue?
    let defaultValue: JSONValue?
    let choices: [JSONValue]?
    let minimum: JSONValue?
    let maximum: JSONValue?
    let minLength: Int?
    let maxLength: Int?

    enum CodingKeys: String, CodingKey {
        case type, description, typetext, format, pattern, optional, minimum, maximum, minLength, maxLength
        case defaultValue = "default"
        case choices = "enum"
    }

    var isOptional: Bool { optional?.text == "1" || optional?.text == "true" }
}

struct APIPermissionsSchema: Decodable {
    let description: String?
}

enum JSONValue: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    var text: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "1" : "0"
        case .object(let value): value.map { "\($0.key)=\($0.value.text)" }.sorted().joined(separator: ", ")
        case .array(let value): value.map(\.text).joined(separator: ", ")
        case .null: ""
        }
    }
}

enum GuestAction: String, CaseIterable, Identifiable {
    case start, shutdown, reboot, stop

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .start: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .stop: "stop.fill"
        }
    }
    var isDestructive: Bool { self == .stop }
}

enum AuthenticationMode: String, CaseIterable, Identifiable {
    case password
    case apiToken

    var id: Self { self }
    var title: String { self == .password ? "Username" : "API Token" }
}

enum ProxmoxAuthentication {
    case password(username: String, password: String)
    case apiToken(id: String, secret: String)
}

struct ProxmoxClient {
    let baseURL: URL
    let authentication: ProxmoxAuthentication
    let allowUntrustedCertificate: Bool

    private struct Authorization {
        let field: String
        let value: String
        let csrf: String?
    }

    func snapshot() async throws -> ProxmoxSnapshot {
        let session = allowUntrustedCertificate
            ? URLSession(configuration: .ephemeral, delegate: CertificateDelegate(host: baseURL.host), delegateQueue: nil)
            : URLSession.shared
        let authorization = try await authorize(session: session)
        async let resources: [ProxmoxResource] = request(
            path: "api2/json/cluster/resources", authorization: authorization, session: session
        )
        let loadedResources = try await resources
        let loadedTasks = (try? await request(
            path: "api2/json/cluster/tasks", authorization: authorization, session: session
        ) as [ProxmoxTask]) ?? []
        return ProxmoxSnapshot(
            nodes: loadedResources.filter { $0.type == "node" },
            guests: loadedResources.filter(\.isGuest),
            storages: loadedResources.filter { $0.type == "storage" },
            tasks: loadedTasks
        )
    }

    func perform(_ action: GuestAction, on resource: ProxmoxResource) async throws -> String {
        guard resource.isGuest, let node = resource.node, let vmid = resource.vmid else {
            throw ProxmoxError.invalidResource
        }
        let session = allowUntrustedCertificate
            ? URLSession(configuration: .ephemeral, delegate: CertificateDelegate(host: baseURL.host), delegateQueue: nil)
            : URLSession.shared
        let authorization = try await authorize(session: session)
        return try await request(
            method: "POST",
            path: "api2/json/nodes/\(node)/\(resource.type)/\(vmid)/status/\(action.rawValue)",
            authorization: authorization,
            session: session
        )
    }

    func guestConfig(for resource: ProxmoxResource) async throws -> [String: JSONValue] {
        let target = try guestTarget(resource)
        let session = makeSession()
        let authorization = try await authorize(session: session)
        return try await request(path: "api2/json/\(target)/config", authorization: authorization, session: session)
    }

    func setGuestConfig(_ key: String, value: String?, for resource: ProxmoxResource) async throws {
        let target = try guestTarget(resource)
        let session = makeSession()
        let authorization = try await authorize(session: session)
        let form = value.map { [key: $0] } ?? ["delete": key]
        try await requestVoid(
            method: "PUT",
            path: "api2/json/\(target)/config",
            form: form,
            authorization: authorization,
            session: session
        )
    }

    func rawRequest(method: String, path: String, form: [String: String]) async throws -> String {
        let session = makeSession()
        let authorization = try await authorize(session: session)
        let query = method == "GET" ? form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } : []
        let data = try await requestData(
            method: method,
            path: path.hasPrefix("api2/") ? path : "api2/json/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))",
            query: query,
            form: method == "GET" ? [:] : form,
            authorization: authorization,
            session: session
        )
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return String(data: data, encoding: .utf8) ?? "Empty response"
        }
        return String(data: pretty, encoding: .utf8) ?? "Empty response"
    }

    func endpoint(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        let session = makeSession()
        let authorization = try await authorize(session: session)
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await request(
            path: "api2/json/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))",
            query: items,
            authorization: authorization,
            session: session
        )
    }

    func operation(method: String, path: String, form: [String: String]) async throws -> JSONValue {
        let session = makeSession()
        let authorization = try await authorize(session: session)
        let query = method == "GET" ? form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } : []
        return try await request(
            method: method,
            path: "api2/json/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))",
            query: query,
            form: method == "GET" ? [:] : form,
            authorization: authorization,
            session: session
        )
    }

    func webSession() async throws -> ProxmoxWebSession {
        guard case .password(let username, let password) = authentication else {
            return ProxmoxWebSession(url: baseURL, cookie: nil)
        }
        let session = makeSession()
        let ticket = try await login(username: username, password: password, session: session)
        let cookie = HTTPCookie(properties: [
            .domain: baseURL.host ?? "",
            .path: "/",
            .name: "PVEAuthCookie",
            .value: ticket.ticket,
            .secure: "TRUE"
        ])
        return ProxmoxWebSession(url: baseURL, cookie: cookie)
    }

    func apiSchema() async throws -> [APISchemaNode] {
        let session = makeSession()
        let url = baseURL.appendingPathComponent("pve-docs/api-viewer/apidoc.js")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProxmoxError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "Could not load the Proxmox API schema.")
        }
        guard let source = String(data: data, encoding: .utf8),
              let start = source.range(of: "const apiSchema = ")?.upperBound,
              let end = source.range(of: "\n;\n\nlet method2cmd", range: start..<source.endIndex)?.lowerBound else {
            throw ProxmoxError.invalidSchema
        }
        return try JSONDecoder().decode([APISchemaNode].self, from: Data(source[start..<end].utf8))
    }

    private func makeSession() -> URLSession {
        allowUntrustedCertificate
            ? URLSession(configuration: .ephemeral, delegate: CertificateDelegate(host: baseURL.host), delegateQueue: nil)
            : URLSession.shared
    }

    private func guestTarget(_ resource: ProxmoxResource) throws -> String {
        guard resource.isGuest, let node = resource.node, let vmid = resource.vmid else {
            throw ProxmoxError.invalidResource
        }
        return "nodes/\(node)/\(resource.type)/\(vmid)"
    }

    private func authorize(session: URLSession) async throws -> Authorization {
        switch authentication {
        case .apiToken(let id, let secret):
            return Authorization(field: "Authorization", value: "PVEAPIToken=\(id)=\(secret)", csrf: nil)
        case .password(let username, let password):
            let ticket = try await login(username: username, password: password, session: session)
            return Authorization(
                field: "Cookie",
                value: "PVEAuthCookie=\(ticket.ticket)",
                csrf: ticket.CSRFPreventionToken
            )
        }
    }

    private func login(username: String, password: String, session: URLSession) async throws -> ProxmoxTicket {
        let url = baseURL.appendingPathComponent("api2/json/access/ticket")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 15

        let ticket: ProxmoxTicket = try await send(request, session: session)
        guard !ticket.ticket.hasPrefix("PVE:tfa!") else { throw ProxmoxError.twoFactorRequired }
        return ticket
    }

    private func request<T: Decodable>(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        form: [String: String] = [:],
        authorization: Authorization,
        session: URLSession
    ) async throws -> T {
        let data = try await requestData(
            method: method, path: path, query: query, form: form, authorization: authorization, session: session
        )
        return try JSONDecoder().decode(ProxmoxResponse<T>.self, from: data).data
    }

    private func requestVoid(
        method: String,
        path: String,
        form: [String: String],
        authorization: Authorization,
        session: URLSession
    ) async throws {
        _ = try await requestData(
            method: method, path: path, form: form, authorization: authorization, session: session
        )
    }

    private func requestData(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        form: [String: String] = [:],
        authorization: Authorization,
        session: URLSession
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization.value, forHTTPHeaderField: authorization.field)
        if let csrf = authorization.csrf {
            request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken")
        }
        if !form.isEmpty {
            var body = URLComponents()
            body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 15
        return try await validatedData(for: request, session: session)
    }

    private func send<T: Decodable>(_ request: URLRequest, session: URLSession) async throws -> T {
        let data = try await validatedData(for: request, session: session)
        return try JSONDecoder().decode(ProxmoxResponse<T>.self, from: data).data
    }

    private func validatedData(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ProxmoxError.http(code, detail)
        }
        return data
    }
}

enum ProxmoxError: LocalizedError {
    case http(Int, String)
    case twoFactorRequired
    case invalidResource
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .http(401, _): "Authentication failed. Check the username/password or API token."
        case .http(let code, let detail): detail.isEmpty ? "Proxmox returned HTTP \(code)." : "Proxmox returned HTTP \(code): \(detail)"
        case .twoFactorRequired: "This account requires two-factor authentication, which is not supported yet."
        case .invalidResource: "This action is not available for that resource."
        case .invalidSchema: "The server returned an API schema the app could not understand."
        }
    }
}

private final class CertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String?
    init(host: String?) { self.host = host }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
final class ProxmoxModel: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? "https://proxmox.example.com:8006"
    @Published var authenticationMode = AuthenticationMode(
        rawValue: UserDefaults.standard.string(forKey: "authenticationMode") ?? ""
    ) ?? .apiToken
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var password = Keychain.load(account: "password") ?? ""
    @Published var tokenID = UserDefaults.standard.string(forKey: "tokenID") ?? ""
    @Published var tokenSecret = Keychain.load(account: "api-token-secret") ?? ""
    @Published var allowUntrustedCertificate = UserDefaults.standard.bool(forKey: "allowUntrustedCertificate")
    @Published var nodes: [ProxmoxResource] = []
    @Published var guests: [ProxmoxResource] = []
    @Published var storages: [ProxmoxResource] = []
    @Published var tasks: [ProxmoxTask] = []
    @Published var isLoading = false
    @Published var activeOperation: String?
    @Published var errorMessage: String?
    private var schemaCache: [APISchemaNode]?

    var isConfigured: Bool {
        guard URL(string: server)?.scheme == "https" else { return false }
        switch authenticationMode {
        case .password: return !username.isEmpty && !password.isEmpty
        case .apiToken: return !tokenID.isEmpty && !tokenSecret.isEmpty
        }
    }

    func refresh() async {
        guard let url = URL(string: server), isConfigured else {
            errorMessage = "Enter an HTTPS server URL and login credentials."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await client(url: url).snapshot()
            nodes = snapshot.nodes.sorted { $0.title < $1.title }
            guests = snapshot.guests.sorted { ($0.vmid ?? 0) < ($1.vmid ?? 0) }
            storages = snapshot.storages.sorted { $0.title < $1.title }
            tasks = snapshot.tasks.sorted { ($0.starttime ?? 0) > ($1.starttime ?? 0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func perform(_ action: GuestAction, on resource: ProxmoxResource) async {
        guard let url = URL(string: server) else { return }
        activeOperation = "\(action.title) \(resource.title)…"
        errorMessage = nil
        defer { activeOperation = nil }
        do {
            _ = try await client(url: url).perform(action, on: resource)
            try await Task.sleep(for: .seconds(1))
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func guestConfig(for resource: ProxmoxResource) async throws -> [String: JSONValue] {
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        return try await client(url: url).guestConfig(for: resource)
    }

    func setGuestConfig(_ key: String, value: String?, for resource: ProxmoxResource) async throws {
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        try await client(url: url).setGuestConfig(key, value: value, for: resource)
    }

    func rawRequest(method: String, path: String, form: [String: String]) async throws -> String {
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        return try await client(url: url).rawRequest(method: method, path: path, form: form)
    }

    func endpoint(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        return try await client(url: url).endpoint(path, query: query)
    }

    func operation(method: String, path: String, form: [String: String]) async throws -> JSONValue {
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        return try await client(url: url).operation(method: method, path: path, form: form)
    }

    func webSession() async throws -> ProxmoxWebSession {
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        return try await client(url: url).webSession()
    }

    func apiSchema() async throws -> [APISchemaNode] {
        if let schemaCache { return schemaCache }
        guard let url = URL(string: server) else { throw URLError(.badURL) }
        let schema = try await client(url: url).apiSchema()
        schemaCache = schema
        return schema
    }

    private func client(url: URL) -> ProxmoxClient {
        ProxmoxClient(
            baseURL: url,
            authentication: authenticationMode == .password
                ? .password(username: username, password: password)
                : .apiToken(id: tokenID, secret: tokenSecret),
            allowUntrustedCertificate: allowUntrustedCertificate
        )
    }

    func save() {
        server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenID = tokenID.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(server, forKey: "server")
        UserDefaults.standard.set(authenticationMode.rawValue, forKey: "authenticationMode")
        UserDefaults.standard.set(username, forKey: "username")
        UserDefaults.standard.set(tokenID, forKey: "tokenID")
        UserDefaults.standard.set(allowUntrustedCertificate, forKey: "allowUntrustedCertificate")
        schemaCache = nil
        do {
            try Keychain.save(password, account: "password")
            try Keychain.save(tokenSecret, account: "api-token-secret")
        } catch { errorMessage = "Could not save credentials: \(error.localizedDescription)" }
    }
}

private enum Keychain {
    static let service = "com.kadenzobel.ProxMobile"

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query.merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
