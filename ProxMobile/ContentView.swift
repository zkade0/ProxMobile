import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { OverviewView() }
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                .tag(0)
            NavigationStack { ResourcesView() }
                .tabItem { Label("Resources", systemImage: "server.rack") }
                .tag(1)
            NavigationStack { TasksView() }
                .tabItem { Label("Tasks", systemImage: "clock.arrow.circlepath") }
                .tag(2)
            NavigationStack { NativeAPIRootView() }
                .tabItem { Label("Manage", systemImage: "wrench.and.screwdriver") }
                .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .tint(.cyan)
        .overlay {
            if model.isLoading || model.activeOperation != nil {
                ProgressView(model.activeOperation ?? "Connecting…")
                    .padding().background(.regularMaterial, in: .rect(cornerRadius: 14))
            }
        }
        .alert("Proxmox", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK") {} } message: { Text(model.errorMessage ?? "Unknown error") }
        .task {
            if model.isConfigured { await model.refresh() }
            else { selection = 4 }
        }
    }
}

private struct FullWebUIView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @State private var session: ProxmoxWebSession?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let session {
                ProxmoxWebView(session: session, allowUntrustedCertificate: model.allowUntrustedCertificate)
                    .ignoresSafeArea(edges: .bottom)
            } else if isLoading {
                ProgressView("Opening full Proxmox UI…")
            } else {
                ContentUnavailableView(
                    "Full UI Unavailable",
                    systemImage: "macwindow",
                    description: Text("Configure a Proxmox connection in Settings.")
                )
            }
        }
        .navigationTitle("Full Proxmox UI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(isLoading || !model.isConfigured)
            }
        }
        .task { if session == nil { await load() } }
    }

    private func load() async {
        guard model.isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do { session = try await model.webSession() }
        catch { model.errorMessage = error.localizedDescription }
    }
}

private struct ProxmoxWebView: UIViewRepresentable {
    let session: ProxmoxWebSession
    let allowUntrustedCertificate: Bool

    func makeCoordinator() -> Coordinator { Coordinator(allowUntrustedCertificate: allowUntrustedCertificate) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        Task { @MainActor in
            if let cookie = session.cookie {
                await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            webView.load(URLRequest(url: session.url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let allowUntrustedCertificate: Bool
        init(allowUntrustedCertificate: Bool) { self.allowUntrustedCertificate = allowUntrustedCertificate }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard allowUntrustedCertificate,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: ProxmoxModel

    private var cpu: Double {
        guard !model.nodes.isEmpty else { return 0 }
        return model.nodes.reduce(0) { $0 + ($1.cpu ?? 0) } / Double(model.nodes.count)
    }
    private var memory: Double { ratio(model.nodes, used: \.mem, total: \.maxmem) }
    private var storage: Double { ratio(model.storages, used: \.disk, total: \.maxdisk) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCard(title: "CPU", value: cpu, detail: "Cluster", color: .cyan)
                MetricCard(title: "Memory", value: memory, detail: bytes(model.nodes.compactMap(\.mem).reduce(0, +)), color: .blue)
                MetricCard(title: "Storage", value: storage, detail: bytes(model.storages.compactMap(\.disk).reduce(0, +)), color: .purple)
                MetricCard(
                    title: "Guests",
                    value: model.guests.isEmpty ? 0 : Double(model.guests.filter(\.isRunning).count) / Double(model.guests.count),
                    detail: "\(model.guests.filter(\.isRunning).count) of \(model.guests.count) running",
                    color: .green
                )
            }
            .padding()

            VStack(alignment: .leading, spacing: 10) {
                Text("Nodes").font(.title2.bold())
                ForEach(model.nodes) { ResourceRow(resource: $0) }
                if !model.tasks.isEmpty {
                    Text("Recent Tasks").font(.title2.bold()).padding(.top, 10)
                    ForEach(model.tasks.prefix(5)) { TaskRow(task: $0) }
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Datacenter")
        .toolbar { RefreshButton() }
        .refreshable { await model.refresh() }
    }
}

private struct ResourcesView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @State private var search = ""

    private func matches(_ resource: ProxmoxResource) -> Bool {
        search.isEmpty || resource.title.localizedCaseInsensitiveContains(search) ||
            String(resource.vmid ?? 0).contains(search)
    }

    var body: some View {
        List {
            ForEach(model.nodes) { node in
                Section {
                    NavigationLink { ResourceDetailView(resource: node) } label: { ResourceRow(resource: node) }
                    ForEach(model.guests.filter { $0.node == node.node && matches($0) }) { guest in
                        NavigationLink { ResourceDetailView(resource: guest) } label: { ResourceRow(resource: guest) }
                    }
                    ForEach(model.storages.filter { $0.node == node.node && matches($0) }) { storage in
                        NavigationLink { ResourceDetailView(resource: storage) } label: { ResourceRow(resource: storage) }
                    }
                } header: { Text(node.title) }
            }
        }
        .navigationTitle("Resources")
        .searchable(text: $search, prompt: "Name or VMID")
        .toolbar { RefreshButton() }
        .refreshable { await model.refresh() }
    }
}

private struct ManagementItem: Identifiable {
    let section: String
    let title: String
    let icon: String
    let path: String
    var query: [String: String] = [:]
    var id: String { "\(section):\(title):\(path)" }
}

private func managementItems(for resource: ProxmoxResource) -> [ManagementItem] {
    guard let node = resource.node else { return [] }

    if resource.type == "node" {
        let base = "nodes/\(node)"
        return [
            .init(section: "System", title: "Status", icon: "gauge.with.dots.needle.50percent", path: "\(base)/status"),
            .init(section: "System", title: "Services", icon: "gearshape.2", path: "\(base)/services"),
            .init(section: "System", title: "Network", icon: "network", path: "\(base)/network"),
            .init(section: "System", title: "Certificates", icon: "checkmark.shield", path: "\(base)/certificates/info"),
            .init(section: "System", title: "DNS", icon: "globe", path: "\(base)/dns"),
            .init(section: "System", title: "Hosts", icon: "list.bullet.rectangle", path: "\(base)/hosts"),
            .init(section: "System", title: "Options", icon: "slider.horizontal.3", path: "\(base)/config"),
            .init(section: "System", title: "Time", icon: "clock", path: "\(base)/time"),
            .init(section: "System", title: "System Log", icon: "doc.text", path: "\(base)/journal"),
            .init(section: "Updates", title: "Package Updates", icon: "arrow.down.circle", path: "\(base)/apt/update"),
            .init(section: "Updates", title: "Repositories", icon: "shippingbox", path: "\(base)/apt/repositories"),
            .init(section: "Firewall", title: "Rules", icon: "shield", path: "\(base)/firewall/rules"),
            .init(section: "Firewall", title: "Options", icon: "shield.lefthalf.filled", path: "\(base)/firewall/options"),
            .init(section: "Firewall", title: "Aliases", icon: "person.text.rectangle", path: "\(base)/firewall/aliases"),
            .init(section: "Firewall", title: "IP Sets", icon: "point.3.connected.trianglepath.dotted", path: "\(base)/firewall/ipset"),
            .init(section: "Firewall", title: "Log", icon: "doc.text.magnifyingglass", path: "\(base)/firewall/log"),
            .init(section: "Disks", title: "Disks", icon: "internaldrive", path: "\(base)/disks/list"),
            .init(section: "Disks", title: "LVM", icon: "externaldrive", path: "\(base)/disks/lvm"),
            .init(section: "Disks", title: "LVM-Thin", icon: "externaldrive.badge.timemachine", path: "\(base)/disks/lvmthin"),
            .init(section: "Disks", title: "Directory", icon: "folder", path: "\(base)/disks/directory"),
            .init(section: "Disks", title: "ZFS", icon: "square.stack.3d.up", path: "\(base)/disks/zfs"),
            .init(section: "Cluster", title: "Ceph", icon: "circle.hexagongrid", path: "\(base)/ceph/status"),
            .init(section: "Cluster", title: "Replication", icon: "arrow.triangle.2.circlepath", path: "\(base)/replication"),
            .init(section: "Cluster", title: "Task History", icon: "clock.arrow.circlepath", path: "\(base)/tasks"),
            .init(section: "Cluster", title: "Subscription", icon: "checkmark.seal", path: "\(base)/subscription")
        ]
    }

    if resource.isGuest, let vmid = resource.vmid {
        let base = "nodes/\(node)/\(resource.type)/\(vmid)"
        return [
            .init(section: "Guest", title: "Current Status", icon: "gauge.with.dots.needle.50percent", path: "\(base)/status/current"),
            .init(section: "Guest", title: "Snapshots", icon: "camera.filters", path: "\(base)/snapshot"),
            .init(section: "Guest", title: "Replication", icon: "arrow.triangle.2.circlepath", path: "nodes/\(node)/replication"),
            .init(section: "Guest", title: "Task History", icon: "clock.arrow.circlepath", path: "nodes/\(node)/tasks", query: ["vmid": String(vmid)]),
            .init(section: "Guest", title: "Backup Jobs", icon: "externaldrive.badge.timemachine", path: "cluster/backup"),
            .init(section: "Firewall", title: "Rules", icon: "shield", path: "\(base)/firewall/rules"),
            .init(section: "Firewall", title: "Options", icon: "shield.lefthalf.filled", path: "\(base)/firewall/options"),
            .init(section: "Firewall", title: "Aliases", icon: "person.text.rectangle", path: "\(base)/firewall/aliases"),
            .init(section: "Firewall", title: "IP Sets", icon: "point.3.connected.trianglepath.dotted", path: "\(base)/firewall/ipset"),
            .init(section: "Firewall", title: "Log", icon: "doc.text.magnifyingglass", path: "\(base)/firewall/log"),
            .init(section: "Access", title: "Permissions", icon: "person.badge.key", path: "access/permissions", query: ["path": "/vms/\(vmid)"])
        ] + (resource.type == "qemu" ? [
            .init(section: "Guest Agent", title: "Network Interfaces", icon: "network", path: "\(base)/agent/network-get-interfaces"),
            .init(section: "Guest Agent", title: "Operating System", icon: "info.circle", path: "\(base)/agent/get-osinfo"),
            .init(section: "Guest Agent", title: "Filesystem", icon: "internaldrive", path: "\(base)/agent/get-fsinfo")
        ] : [])
    }

    if resource.type == "storage", let storage = resource.storage ?? resource.name {
        let base = "nodes/\(node)/storage/\(storage)"
        return [
            .init(section: "Storage", title: "Status", icon: "gauge.with.dots.needle.50percent", path: "\(base)/status"),
            .init(section: "Storage", title: "Content", icon: "doc.on.doc", path: "\(base)/content"),
            .init(section: "Storage", title: "Permissions", icon: "person.badge.key", path: "access/permissions", query: ["path": "/storage/\(storage)"])
        ]
    }
    return []
}

private struct ResourceDetailView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let resource: ProxmoxResource
    @State private var pendingAction: GuestAction?
    @State private var pendingNodeCommand: String?

    private var items: [ManagementItem] { managementItems(for: resource) }
    private var sections: [String] { Array(Set(items.map(\.section))).sorted { sectionOrder($0) < sectionOrder($1) } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: resource.icon)
                        .font(.largeTitle).foregroundStyle(resource.isRunning ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(resource.title).font(.title2.bold())
                        Text("\(resource.subtitle) · \(resource.status ?? "unknown")")
                            .foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Utilization") {
                UsageRow(title: "CPU", value: resource.cpu ?? 0, detail: resource.cpuText)
                UsageRow(
                    title: "Memory",
                    value: fraction(resource.mem, resource.maxmem),
                    detail: resource.memoryText
                )
                if resource.maxdisk != nil {
                    UsageRow(title: "Disk", value: fraction(resource.disk, resource.maxdisk), detail: resource.diskText)
                }
            }
            Section("Details") {
                if let node = resource.node { LabeledContent("Node", value: node) }
                if let vmid = resource.vmid { LabeledContent("VMID", value: String(vmid)) }
                if let uptime = resource.uptime { LabeledContent("Uptime", value: uptimeText(uptime)) }
                if let tags = resource.tags, !tags.isEmpty { LabeledContent("Tags", value: tags.replacingOccurrences(of: ";", with: ", ")) }
                if let netin = resource.netin { LabeledContent("Network In", value: bytes(netin)) }
                if let netout = resource.netout { LabeledContent("Network Out", value: bytes(netout)) }
            }
            if resource.isGuest {
                Section("Configuration") {
                    NavigationLink {
                        NativeExactOperationView(
                            title: "\(resource.title) Configuration",
                            path: "/nodes/{node}/\(resource.type)/{vmid}/config",
                            method: "PUT",
                            knownValues: ["node": resource.node ?? "", "vmid": String(resource.vmid ?? 0)]
                        )
                    } label: { Label("All Predefined Settings", systemImage: "slider.horizontal.3") }
                }
            }
            if let scope = nativeScope(for: resource) {
                Section("Native Management") {
                    NavigationLink {
                        NativeOperationsView(title: "\(resource.title) Operations", pathPrefix: scope.path, knownValues: scope.values)
                    } label: {
                        Label("All Actions & Settings", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(items.filter { $0.section == section }) { item in
                        NavigationLink {
                            NativeEndpointView(item: item)
                        } label: { Label(item.title, systemImage: item.icon) }
                    }
                }
            }
            Section("Advanced") {
                NavigationLink {
                    APIExplorerView(defaultPath: defaultAPIPath(for: resource))
                } label: { Label("API Explorer", systemImage: "terminal") }
            }
        }
        .navigationTitle(resource.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if resource.isGuest {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Power", systemImage: "power") {
                        ForEach(GuestAction.allCases) { action in
                            Button(action.title, systemImage: action.icon, role: action.isDestructive ? .destructive : nil) {
                                pendingAction = action
                            }
                        }
                    }
                }
            }
            if resource.type == "node" {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Power", systemImage: "power") {
                        Button("Reboot", systemImage: "arrow.clockwise") { pendingNodeCommand = "reboot" }
                        Button("Shutdown", systemImage: "power", role: .destructive) { pendingNodeCommand = "shutdown" }
                    }
                }
            }
        }
        .confirmationDialog(
            "Confirm \(pendingAction?.title ?? "Action")",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    Task { await model.perform(action, on: resource) }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("This will \(pendingAction?.title.lowercased() ?? "change") \(resource.title) on \(resource.node ?? "its node").")
        }
        .confirmationDialog(
            "Confirm node \(pendingNodeCommand ?? "action")",
            isPresented: Binding(get: { pendingNodeCommand != nil }, set: { if !$0 { pendingNodeCommand = nil } }),
            titleVisibility: .visible
        ) {
            if let command = pendingNodeCommand {
                Button(command.capitalized, role: command == "shutdown" ? .destructive : nil) {
                    Task { await runNodeCommand(command) }
                }
            }
            Button("Cancel", role: .cancel) { pendingNodeCommand = nil }
        } message: { Text("This will \(pendingNodeCommand ?? "change") the Proxmox host \(resource.node ?? resource.title).") }
    }

    private func runNodeCommand(_ command: String) async {
        pendingNodeCommand = nil
        do {
            _ = try await model.rawRequest(
                method: "POST", path: "nodes/\(resource.node ?? resource.title)/status", form: ["command": command]
            )
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private func sectionOrder(_ section: String) -> Int {
    ["System", "Guest", "Guest Agent", "Storage", "Updates", "Firewall", "Disks", "Cluster", "Access"].firstIndex(of: section) ?? 99
}

private func defaultAPIPath(for resource: ProxmoxResource) -> String {
    if resource.isGuest { return "nodes/\(resource.node ?? "")/\(resource.type)/\(resource.vmid ?? 0)" }
    if resource.type == "node" { return "nodes/\(resource.node ?? resource.title)" }
    if resource.type == "storage" { return "nodes/\(resource.node ?? "")/storage/\(resource.storage ?? resource.name ?? "")" }
    return "cluster/resources"
}

private struct NativeEndpointView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let item: ManagementItem
    @State private var value: JSONValue?
    @State private var isLoading = false

    var body: some View {
        List {
            if let value {
                EndpointValueView(value: value)
            } else if !isLoading {
                ContentUnavailableView("No Data", systemImage: item.icon, description: Text("Pull down to try again."))
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NativeConcreteOperationsView(title: "\(item.title) Actions", concretePrefix: "/\(item.path)")
                } label: {
                    Label("Actions", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { value = try await model.endpoint(item.path, query: item.query) }
        catch { model.errorMessage = error.localizedDescription }
    }
}

private struct EndpointValueView: View {
    let value: JSONValue

    var body: some View { rendered(value) }

    private func rendered(_ value: JSONValue) -> AnyView {
        switch value {
        case .object(let object):
            return AnyView(ForEach(object.keys.sorted(), id: \.self) { key in
                if let child = object[key] {
                    if child.isScalar {
                        LabeledContent(key, value: child.text.isEmpty ? "—" : child.text)
                    } else {
                        DisclosureGroup(key) { rendered(child) }
                    }
                }
            })
        case .array(let array):
            return AnyView(ForEach(Array(array.enumerated()), id: \.offset) { index, child in
                if child.isScalar {
                    Text(child.text.isEmpty ? "—" : child.text).textSelection(.enabled)
                } else {
                    DisclosureGroup(child.displayName ?? "Item \(index + 1)") { rendered(child) }
                }
            })
        case .string, .number, .bool, .null:
            return AnyView(Text(value.text.isEmpty ? "—" : value.text).textSelection(.enabled))
        }
    }
}

private extension JSONValue {
    var isScalar: Bool {
        switch self {
        case .object, .array: false
        default: true
        }
    }

    var displayName: String? {
        guard case .object(let object) = self else { return nil }
        for key in ["name", "id", "vmid", "storage", "service", "devpath", "type"] {
            if let value = object[key]?.text, !value.isEmpty { return value }
        }
        return nil
    }
}

private struct TasksView: View {
    @EnvironmentObject private var model: ProxmoxModel

    var body: some View {
        List(model.tasks) { task in TaskRow(task: task) }
            .navigationTitle("Tasks")
            .toolbar { RefreshButton() }
            .refreshable { await model.refresh() }
            .overlay {
                if model.tasks.isEmpty && !model.isLoading {
                    ContentUnavailableView("No Tasks", systemImage: "clock", description: Text("Task history will appear after connecting."))
                }
            }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: ProxmoxModel

    var body: some View {
        Form {
            Section("Connection") {
                TextField("https://host:8006", text: $model.server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Picker("Authentication", selection: $model.authenticationMode) {
                    ForEach(AuthenticationMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
                if model.authenticationMode == .password {
                    TextField("root@pam or user@pve", text: $model.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $model.password)
                } else {
                    TextField("user@realm!token-name", text: $model.tokenID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token secret", text: $model.tokenSecret)
                }
            }
            Section {
                Toggle("Allow untrusted certificate", isOn: $model.allowUntrustedCertificate)
            } footer: { Text("Use only for a known server on a trusted LAN.") }
            Section {
                Button("Save and Connect") {
                    model.save()
                    guard model.errorMessage == nil else { return }
                    Task { await model.refresh() }
                }.disabled(!model.isConfigured)
            }
            Section("Security") {
                Text(model.authenticationMode == .password
                     ? "Password is stored in Keychain. Guest actions use a short-lived ticket and CSRF token."
                     : "Token secret is stored in Keychain. Permissions control which views and actions are available.")
            }
            Section("Administration") {
                NavigationLink {
                    FullWebUIView()
                } label: { Label("Official Web UI", systemImage: "macwindow") }
                NavigationLink {
                    APIExplorerView(defaultPath: "cluster/resources")
                } label: { Label("Advanced API Explorer", systemImage: "terminal") }
            }
        }
        .navigationTitle("Settings")
    }
}

private struct NativeScope {
    let path: String
    let values: [String: String]
}

private func nativeScope(for resource: ProxmoxResource) -> NativeScope? {
    guard let node = resource.node else { return nil }
    if resource.type == "node" {
        return NativeScope(path: "/nodes/{node}", values: ["node": node])
    }
    if resource.isGuest, let vmid = resource.vmid {
        return NativeScope(
            path: "/nodes/{node}/\(resource.type)/{vmid}",
            values: ["node": node, "vmid": String(vmid)]
        )
    }
    if resource.type == "storage", let storage = resource.storage ?? resource.name {
        return NativeScope(
            path: "/nodes/{node}/storage/{storage}",
            values: ["node": node, "storage": storage]
        )
    }
    return nil
}

private struct ConfigItem: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

private struct GuestConfigView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let resource: ProxmoxResource
    @State private var values: [String: JSONValue] = [:]
    @State private var selected: ConfigItem?
    @State private var pendingDelete: ConfigItem?
    @State private var editValue = ""
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var showingAdd = false
    @State private var isLoading = false

    private var items: [ConfigItem] {
        values.filter { $0.key != "digest" }
            .map { ConfigItem(key: $0.key, value: $0.value.text) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(["Hardware", "Cloud-Init", "Options"], id: \.self) { category in
                let sectionItems = items.filter { configCategory($0.key, type: resource.type) == category }
                if !sectionItems.isEmpty {
                    Section(category) {
                        ForEach(sectionItems) { item in
                            Button {
                                selected = item
                                editValue = item.value
                            } label: {
                                LabeledContent(item.key) {
                                    Text(item.value.isEmpty ? "—" : item.value)
                                        .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = item
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("\(resource.title) Config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add setting", systemImage: "plus") { showingAdd = true }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { item in
            NavigationStack {
                Form {
                    Section(item.key) {
                        TextField("Value", text: $editValue, axis: .vertical).lineLimit(3...10)
                    }
                    Section {
                        Text("Complex values use Proxmox's native comma-separated API syntax.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Edit Setting")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selected = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save(item.key, value: editValue); selected = nil } }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                Form {
                    TextField("API key", text: $newKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Value", text: $newValue, axis: .vertical).lineLimit(3...10)
                }
                .navigationTitle("Add Setting")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingAdd = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                await save(newKey, value: newValue)
                                newKey = ""; newValue = ""; showingAdd = false
                            }
                        }.disabled(newKey.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.key ?? "setting")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let item = pendingDelete {
                Button("Delete", role: .destructive) { Task { await save(item.key, value: nil); pendingDelete = nil } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Proxmox will remove this value and may restore its default behavior.")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { values = try await model.guestConfig(for: resource) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func save(_ key: String, value: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.setGuestConfig(key, value: value, for: resource)
            values = try await model.guestConfig(for: resource)
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct APIExplorerView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @State private var method = "GET"
    @State private var path: String
    @State private var parameters = ""
    @State private var output = ""
    @State private var isRunning = false
    @State private var confirmingWrite = false

    init(defaultPath: String) { _path = State(initialValue: defaultPath) }

    var body: some View {
        Form {
            Section("Request") {
                Picker("Method", selection: $method) {
                    ForEach(["GET", "POST", "PUT", "DELETE"], id: \.self, content: Text.init)
                }.pickerStyle(.segmented)
                TextField("API path", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("key=value, one per line", text: $parameters, axis: .vertical).lineLimit(3...8)
                Button(isRunning ? "Running…" : "Send Request") {
                    if method == "GET" { Task { await run() } }
                    else { confirmingWrite = true }
                }.disabled(path.isEmpty || isRunning)
            }
            if !output.isEmpty {
                Section("Response") {
                    ScrollView(.horizontal) { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            Section {
                Text("This authenticated fallback exposes the complete Proxmox API while dedicated native screens are added. Non-GET requests can modify or delete infrastructure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Advanced API")
        .confirmationDialog("Send \(method) request?", isPresented: $confirmingWrite, titleVisibility: .visible) {
            Button("Send \(method)", role: method == "DELETE" ? .destructive : nil) { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(method) /api2/json/\(path)") }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        var form: [String: String] = [:]
        for line in parameters.split(whereSeparator: \.isNewline) {
            guard let index = line.firstIndex(of: "=") else { continue }
            form[String(line[..<index])] = String(line[line.index(after: index)...])
        }
        do { output = try await model.rawRequest(method: method, path: path, form: form) }
        catch { output = error.localizedDescription }
    }
}

private struct MetricCard: View {
    let title: String
    let value: Double
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Gauge(value: value.clamped) { EmptyView() }
                .gaugeStyle(.accessoryCircularCapacity).tint(color).scaleEffect(1.2)
            Text(value.clamped.formatted(.percent.precision(.fractionLength(0))))
                .font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.thinMaterial, in: .rect(cornerRadius: 16))
    }
}

private struct ResourceRow: View {
    let resource: ProxmoxResource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resource.icon)
                .frame(width: 24).foregroundStyle(resource.isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.title).font(.headline)
                Text("\(resource.subtitle) · \(resource.status ?? "available")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if resource.type != "storage" {
                Text(resource.cpuText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(resource.diskText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

private struct TaskRow: View {
    let task: ProxmoxTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.isRunning ? "progress.indicator" : (task.status == "OK" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(task.isRunning ? .cyan : (task.status == "OK" ? .green : .orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(task.type).font(.headline)
                Text("\(task.node) · \(task.user ?? "system")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(task.result).font(.caption.bold())
                if let started = task.started { Text(started, style: .relative).font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 3)
    }
}

private struct UsageRow: View {
    let title: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title); Spacer(); Text(detail).foregroundStyle(.secondary).monospacedDigit() }
            ProgressView(value: value.clamped).tint(value > 0.9 ? .red : .cyan)
        }.padding(.vertical, 3)
    }
}

private struct RefreshButton: ToolbarContent {
    @EnvironmentObject private var model: ProxmoxModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .disabled(model.isLoading || !model.isConfigured)
        }
    }
}

private extension Double {
    var clamped: Double { min(max(self.isFinite ? self : 0, 0), 1) }
}

private func fraction(_ used: Double?, _ total: Double?) -> Double {
    guard let used, let total, total > 0 else { return 0 }
    return used / total
}

private func ratio(_ resources: [ProxmoxResource], used: KeyPath<ProxmoxResource, Double?>, total: KeyPath<ProxmoxResource, Double?>) -> Double {
    let usedValue = resources.compactMap { $0[keyPath: used] }.reduce(0, +)
    let totalValue = resources.compactMap { $0[keyPath: total] }.reduce(0, +)
    return totalValue > 0 ? usedValue / totalValue : 0
}

private func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
}

private func uptimeText(_ seconds: Double) -> String {
    let days = Int(seconds) / 86_400
    let hours = (Int(seconds) % 86_400) / 3_600
    return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
}

private func configCategory(_ key: String, type: String) -> String {
    let hardwarePrefixes = [
        "memory", "swap", "cores", "sockets", "cpu", "numa", "balloon", "hugepages",
        "scsi", "sata", "ide", "virtio", "rootfs", "mp", "net", "hostpci", "usb",
        "efidisk", "tpmstate", "serial", "parallel", "audio", "vga", "machine", "bios"
    ]
    let cloudInitPrefixes = ["ci", "ipconfig", "sshkeys", "nameserver", "searchdomain"]
    if type == "qemu" && cloudInitPrefixes.contains(where: key.hasPrefix) { return "Cloud-Init" }
    if hardwarePrefixes.contains(where: key.hasPrefix) { return "Hardware" }
    return "Options"
}
