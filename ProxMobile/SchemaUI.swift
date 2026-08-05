import SwiftUI

struct APIOperation: Identifiable {
    let path: String
    let method: String
    let schema: APIMethodSchema
    var id: String { "\(method):\(path)" }

    var title: String {
        if schema.name == "create_vm" { return path.hasSuffix("/qemu") ? "Create Virtual Machine" : "Create Container" }
        if let mapped = friendlyActionNames[schema.name ?? ""] { return mapped }
        if let description = schema.description?.split(separator: ".").first, !description.isEmpty {
            return String(description).replacingOccurrences(of: "VM", with: "Virtual Machine")
        }
        return featureName(path)
    }

    var isWrite: Bool { method != "GET" }
    var isDestructive: Bool { method == "DELETE" }
}

private func flattenOperations(_ nodes: [APISchemaNode]) -> [APIOperation] {
    nodes.flatMap { node in
        let own = (node.info ?? [:]).compactMap { method, schema in
            ["GET", "POST", "PUT", "DELETE"].contains(method) ? APIOperation(path: node.path, method: method, schema: schema) : nil
        }
        return own + flattenOperations(node.children ?? [])
    }
}

private struct ParameterGroup: Identifiable {
    let title: String
    let parameters: [(String, APIParameterSchema)]
    var id: String { title }
}

struct NativeAPIRootView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @State private var schema: [APISchemaNode] = []
    @State private var search = ""
    @State private var isLoading = false

    private var operations: [APIOperation] {
        let all = flattenOperations(schema)
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.path.localizedCaseInsensitiveContains(search) ||
            $0.title.localizedCaseInsensitiveContains(search) ||
            ($0.schema.description ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var allOperations: [APIOperation] { flattenOperations(schema) }

    private let datacenterCategories = [
        ("Cluster", "point.3.connected.trianglepath.dotted", "/cluster"),
        ("Storage Configuration", "externaldrive", "/storage"),
        ("Users & Permissions", "person.2", "/access"),
        ("Resource Pools", "square.stack.3d.up", "/pools"),
        ("Backup Jobs", "externaldrive.badge.timemachine", "/cluster/backup"),
        ("Replication", "arrow.triangle.2.circlepath", "/cluster/replication"),
        ("High Availability", "heart.text.square", "/cluster/ha"),
        ("Firewall", "shield", "/cluster/firewall"),
        ("Software Defined Network", "network", "/cluster/sdn"),
        ("ACME Certificates", "checkmark.shield", "/cluster/acme"),
        ("Notifications", "bell", "/cluster/notifications")
    ]

    var body: some View {
        List {
            Section {
                Text("Every operation and predefined parameter below comes from this Proxmox server's own API schema.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if search.isEmpty {
                if let createVM = operation(path: "/nodes/{node}/qemu", method: "POST"),
                   let createCT = operation(path: "/nodes/{node}/lxc", method: "POST") {
                    Section("Create") {
                        ForEach(model.nodes) { node in
                            NavigationLink {
                                APIOperationForm(operation: createVM, knownValues: ["node": node.node ?? node.title])
                            } label: { Label("Create VM on \(node.title)", systemImage: "desktopcomputer") }
                            NavigationLink {
                                APIOperationForm(operation: createCT, knownValues: ["node": node.node ?? node.title])
                            } label: { Label("Create Container on \(node.title)", systemImage: "shippingbox") }
                        }
                    }
                }

                Section("Datacenter") {
                    ForEach(datacenterCategories, id: \.0) { title, icon, prefix in
                        NavigationLink {
                            NativeOperationsView(title: title, pathPrefix: prefix, knownValues: [:])
                        } label: { Label(title, systemImage: icon) }
                    }
                }

                Section("Nodes") {
                    ForEach(model.nodes) { node in
                        NavigationLink {
                            NativeOperationsView(
                                title: node.title,
                                pathPrefix: "/nodes/{node}",
                                knownValues: ["node": node.node ?? node.title]
                            )
                        } label: { Label(node.title, systemImage: "server.rack") }
                    }
                }

                Section("Virtual Machines & Containers") {
                    ForEach(model.guests) { guest in
                        if let node = guest.node, let vmid = guest.vmid {
                            NavigationLink {
                                NativeOperationsView(
                                    title: guest.title,
                                    pathPrefix: "/nodes/{node}/\(guest.type)/{vmid}",
                                    knownValues: ["node": node, "vmid": String(vmid)]
                                )
                            } label: { Label("\(vmid) \(guest.title)", systemImage: guest.icon) }
                        }
                    }
                }

                Section("Storage") {
                    ForEach(model.storages) { storage in
                        if let node = storage.node, let name = storage.storage ?? storage.name {
                            NavigationLink {
                                NativeOperationsView(
                                    title: storage.title,
                                    pathPrefix: "/nodes/{node}/storage/{storage}",
                                    knownValues: ["node": node, "storage": name]
                                )
                            } label: { Label(storage.title, systemImage: "externaldrive") }
                        }
                    }
                }

                Section("Complete API") {
                    NavigationLink {
                        NativeOperationsView(title: "All Operations", pathPrefix: "", knownValues: [:])
                    } label: { Label("Browse Every Operation", systemImage: "list.bullet.rectangle") }
                }
            } else {
                operationList(operations)
            }
        }
        .navigationTitle("Manage")
        .searchable(text: $search, prompt: "VM, storage, firewall…")
        .overlay { if isLoading { ProgressView("Loading API schema…") } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func operation(path: String, method: String) -> APIOperation? {
        allOperations.first { $0.path == path && $0.method == method }
    }

    @ViewBuilder private func operationList(_ operations: [APIOperation]) -> some View {
        ForEach(operations) { operation in
            NavigationLink {
                APIOperationForm(operation: operation, knownValues: [:])
            } label: {
                OperationRow(operation: operation)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { schema = try await model.apiSchema() }
        catch { model.errorMessage = error.localizedDescription }
    }
}

struct NativeOperationsView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let title: String
    let pathPrefix: String
    let knownValues: [String: String]
    @State private var operations: [APIOperation] = []
    @State private var search = ""
    @State private var isLoading = false

    private var filtered: [APIOperation] {
        guard !search.isEmpty else { return operations }
        return operations.filter {
            $0.path.localizedCaseInsensitiveContains(search) ||
            $0.title.localizedCaseInsensitiveContains(search) ||
            ($0.schema.description ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(filtered) { operation in
            NavigationLink {
                APIOperationForm(operation: operation, knownValues: knownValues)
            } label: { OperationRow(operation: operation, prefix: pathPrefix) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search operations")
        .overlay {
            if isLoading { ProgressView("Loading operations…") }
            else if operations.isEmpty { ContentUnavailableView("No Operations", systemImage: "wrench.and.screwdriver") }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            operations = flattenOperations(try await model.apiSchema())
                .filter { pathPrefix.isEmpty || $0.path == pathPrefix || $0.path.hasPrefix(pathPrefix + "/") }
                .sorted { ($0.path, methodOrder($0.method)) < ($1.path, methodOrder($1.method)) }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct BoundOperation: Identifiable {
    let operation: APIOperation
    let values: [String: String]
    var id: String { operation.id }
}

struct NativeConcreteOperationsView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let title: String
    let concretePrefix: String
    @State private var operations: [BoundOperation] = []
    @State private var search = ""
    @State private var isLoading = false

    private var filtered: [BoundOperation] {
        guard !search.isEmpty else { return operations }
        return operations.filter {
            $0.operation.title.localizedCaseInsensitiveContains(search) ||
            $0.operation.path.localizedCaseInsensitiveContains(search) ||
            ($0.operation.schema.description ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(filtered) { item in
            NavigationLink {
                APIOperationForm(operation: item.operation, knownValues: item.values)
            } label: { OperationRow(operation: item.operation) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search actions")
        .overlay {
            if isLoading { ProgressView("Loading actions…") }
            else if operations.isEmpty { ContentUnavailableView("No Actions", systemImage: "wrench.and.screwdriver") }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            operations = flattenOperations(try await model.apiSchema()).compactMap { operation in
                bind(operation: operation, to: concretePrefix)
            }.sorted { ($0.operation.path, methodOrder($0.operation.method)) < ($1.operation.path, methodOrder($1.operation.method)) }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

struct NativeExactOperationView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let title: String
    let path: String
    let method: String
    let knownValues: [String: String]
    @State private var operation: APIOperation?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let operation {
                APIOperationForm(operation: operation, knownValues: knownValues)
            } else if isLoading {
                ProgressView("Loading form…")
            } else {
                ContentUnavailableView("Form Unavailable", systemImage: "doc.badge.gearshape")
            }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            operation = flattenOperations(try await model.apiSchema()).first { $0.path == path && $0.method == method }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private func bind(operation: APIOperation, to concretePrefix: String) -> BoundOperation? {
    let pattern = operation.path.split(separator: "/").map(String.init)
    let concrete = concretePrefix.split(separator: "/").map(String.init)
    guard pattern.count >= concrete.count else { return nil }
    var values: [String: String] = [:]
    for index in concrete.indices {
        let part = pattern[index]
        if part.hasPrefix("{"), part.hasSuffix("}") {
            values[String(part.dropFirst().dropLast())] = concrete[index]
        } else if part != concrete[index] {
            return nil
        }
    }
    return BoundOperation(operation: operation, values: values)
}

private struct OperationRow: View {
    let operation: APIOperation
    var prefix = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: actionIcon(operation))
                .foregroundStyle(operation.isDestructive ? .red : .cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.title).font(.headline)
                if let description = operation.schema.description {
                    Text(description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }.padding(.vertical, 3)
    }

    private var relativePath: String {
        guard !prefix.isEmpty else { return operation.path }
        let value = operation.path.replacingOccurrences(of: prefix, with: "")
        return value.isEmpty ? "/" : value
    }
}

struct APIOperationForm: View {
    @EnvironmentObject private var model: ProxmoxModel
    let operation: APIOperation
    let knownValues: [String: String]
    @State private var values: [String: String]
    @State private var result: JSONValue?
    @State private var resultMessage = ""
    @State private var isRunning = false
    @State private var confirming = false
    @State private var loadedCurrentValues = false

    private var parameters: [(String, APIParameterSchema)] {
        (operation.schema.parameters?.properties ?? [:]).sorted {
            let leftPath = operation.path.contains("{\($0.key)}")
            let rightPath = operation.path.contains("{\($1.key)}")
            if leftPath != rightPath { return leftPath }
            if $0.value.isOptional != $1.value.isOptional { return !$0.value.isOptional }
            return $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }
    }

    private var parameterGroups: [ParameterGroup] {
        let editable = parameters.filter { knownValues[$0.0] == nil }
        let order = ["Required", "General", "Compute", "Storage", "Network", "Cloud-Init", "Security", "Scheduling", "Advanced"]
        let grouped = Dictionary(grouping: editable) { name, parameter in
            parameterGroup(for: name, required: !parameter.isOptional)
        }
        return order.compactMap { title in
            guard let values = grouped[title], !values.isEmpty else { return nil }
            return ParameterGroup(title: title, parameters: values)
        }
    }

    init(operation: APIOperation, knownValues: [String: String]) {
        self.operation = operation
        self.knownValues = knownValues
        var initial = knownValues
        for (name, parameter) in operation.schema.parameters?.properties ?? [:] {
            if initial[name] == nil, let value = parameter.defaultValue?.text, !parameter.isOptional {
                initial[name] = value
            }
        }
        _values = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                if let description = operation.schema.description { Text(description).font(.footnote) }
                if let permission = operation.schema.permissions?.description {
                    Label(permission, systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !knownValues.isEmpty {
                Section("Target") {
                    ForEach(knownValues.keys.sorted(), id: \.self) { key in
                        LabeledContent(fieldLabel(key), value: knownValues[key] ?? "")
                    }
                }
            }

            ForEach(parameterGroups) { group in
                Section(group.title) {
                    ForEach(group.parameters, id: \.0) { name, parameter in
                        ParameterField(
                            name: name,
                            parameter: parameter,
                            dynamicChoices: dynamicChoices(for: name),
                            value: valueBinding(name)
                        )
                    }
                }
            }

            Section {
                Button(buttonTitle, role: operation.isDestructive ? .destructive : nil) {
                    if operation.isWrite { confirming = true }
                    else { Task { await run() } }
                }
                .disabled(isRunning || formValidationError != nil)

                if operation.method == "PUT", allPathValuesPresent {
                    Button("Load Current Values", systemImage: "arrow.down.doc") { Task { await loadCurrentValues() } }
                        .disabled(isRunning)
                }
            }

            if !resultMessage.isEmpty {
                Section("Result") {
                    Label(resultMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if let result, operation.method == "GET" {
                Section("Details") {
                    SchemaResultView(value: result)
                }
            }
        }
        .navigationTitle(operation.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isRunning { ProgressView("Contacting Proxmox…") } }
        .task {
            if operation.method == "PUT", allPathValuesPresent, !loadedCurrentValues {
                await loadCurrentValues(silent: true)
            }
        }
        .confirmationDialog(
            "Confirm \(operation.method) operation",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(buttonTitle, role: operation.isDestructive ? .destructive : nil) { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(operation.schema.description ?? "This changes Proxmox configuration.")
        }
    }

    private var buttonTitle: String {
        isRunning ? "Working…" : (operation.method == "GET" ? "Load" : operation.title)
    }

    private var pathParameterNames: [String] {
        parameters.map(\.0).filter { operation.path.contains("{\($0)}") }
    }

    private var allPathValuesPresent: Bool {
        pathParameterNames.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    private var formValidationError: String? {
        for (name, parameter) in parameters {
            let value = values[name] ?? ""
            if !parameter.isOptional && value.isEmpty { return "\(fieldLabel(name)) is required." }
            if let error = validate(value, for: parameter) { return "\(fieldLabel(name)): \(error)" }
        }
        return nil
    }

    private var resolvedPath: String {
        var path = operation.path
        for name in pathParameterNames {
            let value = values[name] ?? ""
            path = path.replacingOccurrences(of: "{\(name)}", with: value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value)
        }
        return path
    }

    private var formValues: [String: String] {
        let pathNames = Set(pathParameterNames)
        return values.filter { !pathNames.contains($0.key) && !$0.value.isEmpty }
    }

    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func dynamicChoices(for name: String) -> [String] {
        switch name {
        case "node", "target": model.nodes.compactMap(\.node)
        case "storage": model.storages.compactMap { $0.storage ?? $0.name }
        case "vmid": model.guests.compactMap { $0.vmid.map(String.init) }
        default: []
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            result = try await model.operation(method: operation.method, path: resolvedPath, form: formValues)
            if operation.isWrite {
                resultMessage = result?.text.hasPrefix("UPID:") == true
                    ? "Task started. Progress is available in Tasks."
                    : "Completed successfully."
                await model.refresh()
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func loadCurrentValues(silent: Bool = false) async {
        isRunning = true
        defer { isRunning = false }
        do {
            let current = try await model.endpoint(resolvedPath)
            guard case .object(let object) = current else { return }
            for (name, value) in object where operation.schema.parameters?.properties?[name] != nil {
                values[name] = value.text
            }
            loadedCurrentValues = true
        } catch { if !silent { model.errorMessage = error.localizedDescription } }
    }
}

private struct SchemaResultView: View {
    let value: JSONValue
    var body: some View { render(value) }

    private func render(_ value: JSONValue) -> AnyView {
        switch value {
        case .object(let object):
            AnyView(ForEach(object.keys.sorted(), id: \.self) { key in
                if let child = object[key] {
                    if child.schemaScalar { LabeledContent(fieldLabel(key), value: child.text.isEmpty ? "—" : child.text) }
                    else { DisclosureGroup(fieldLabel(key)) { render(child) } }
                }
            })
        case .array(let values):
            AnyView(ForEach(Array(values.enumerated()), id: \.offset) { index, child in
                if child.schemaScalar { Text(child.text.isEmpty ? "—" : child.text) }
                else { DisclosureGroup("Item \(index + 1)") { render(child) } }
            })
        case .string, .number, .bool, .null:
            AnyView(Text(value.text.isEmpty ? "—" : value.text))
        }
    }
}

private extension JSONValue {
    var schemaScalar: Bool {
        switch self { case .object, .array: false; default: true }
    }
}

private struct ParameterField: View {
    let name: String
    let parameter: APIParameterSchema
    let dynamicChoices: [String]
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if parameter.type == "boolean" {
                Toggle(isOn: Binding(get: { value == "1" }, set: { value = $0 ? "1" : "0" })) {
                    fieldTitle
                }
            } else if !availableChoices.isEmpty {
                Picker(selection: $value) {
                    if parameter.isOptional { Text("Not set").tag("") }
                    ForEach(availableChoices, id: \.self) { Text($0).tag($0) }
                } label: { fieldTitle }
            } else if isSecret {
                SecureField(fieldLabel(name), text: $value)
            } else {
                TextField(fieldLabel(name), text: $value, axis: .vertical)
                    .lineLimit(1...5)
                    .keyboardType(parameter.type == "integer" || parameter.type == "number" ? .numbersAndPunctuation : .default)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if let description = parameter.description {
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = validate(value, for: parameter) {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            if parameter.description == nil, let type = parameter.typetext ?? parameter.type {
                Text(type).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }

    private var fieldTitle: some View {
        HStack {
            Text(fieldLabel(name))
            if !parameter.isOptional { Text("Required").font(.caption2).foregroundStyle(.orange) }
        }
    }

    private var isSecret: Bool {
        let lower = name.lowercased()
        return lower.contains("password") || lower.contains("secret")
    }


    private var availableChoices: [String] {
        let schemaChoices = parameter.choices?.map(\.text) ?? []
        return schemaChoices.isEmpty ? dynamicChoices : schemaChoices
    }
}

private func parameterGroup(for name: String, required: Bool) -> String {
    if required { return "Required" }
    let lower = name.lowercased()
    if ["cores", "sockets", "cpu", "memory", "balloon", "numa", "vga", "machine", "bios", "arch"].contains(where: lower.hasPrefix) { return "Compute" }
    if ["scsi", "sata", "ide", "virtio", "rootfs", "mp", "efidisk", "tpmstate", "storage", "volume", "disk", "pool"].contains(where: lower.hasPrefix) { return "Storage" }
    if ["net", "ip", "bridge", "gateway", "nameserver", "searchdomain", "mac", "firewall"].contains(where: lower.hasPrefix) { return "Network" }
    if ["ci", "sshkeys", "ipconfig"].contains(where: lower.hasPrefix) { return "Cloud-Init" }
    if lower.contains("password") || lower.contains("secret") || lower.contains("key") || lower.contains("role") || lower.contains("permission") || lower.contains("tfa") { return "Security" }
    if lower.contains("schedule") || lower.contains("start") || lower.contains("timeout") || lower.contains("retention") || lower.hasPrefix("keep") || lower.contains("prune") { return "Scheduling" }
    if ["name", "description", "comment", "tags", "enabled", "pool", "type", "template", "ostype"].contains(lower) { return "General" }
    return "Advanced"
}

private func validate(_ value: String, for parameter: APIParameterSchema) -> String? {
    guard !value.isEmpty else { return nil }
    if parameter.type == "integer", Int64(value) == nil { return "Enter a whole number." }
    if parameter.type == "number", Double(value) == nil { return "Enter a number." }
    if let minimum = parameter.minimum.flatMap({ Double($0.text) }), let number = Double(value), number < minimum {
        return "Minimum is \(minimum.formatted())."
    }
    if let maximum = parameter.maximum.flatMap({ Double($0.text) }), let number = Double(value), number > maximum {
        return "Maximum is \(maximum.formatted())."
    }
    if let minLength = parameter.minLength, value.count < minLength { return "Use at least \(minLength) characters." }
    if let maxLength = parameter.maxLength, value.count > maxLength { return "Use no more than \(maxLength) characters." }
    if let pattern = parameter.pattern,
       let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$"),
       regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil {
        return "Value does not match the required format."
    }
    return nil
}

private func fieldLabel(_ name: String) -> String {
    let special = [
        "vmid": "VM ID", "upid": "Task ID", "userid": "User ID", "poolid": "Pool ID",
        "ostype": "OS Type", "bios": "BIOS", "cpu": "CPU", "ip": "IP Address",
        "macaddr": "MAC Address", "bwlimit": "Bandwidth Limit", "snapname": "Snapshot Name"
    ]
    if let value = special[name] { return value }
    return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
}

private func methodOrder(_ method: String) -> Int {
    ["GET", "POST", "PUT", "DELETE"].firstIndex(of: method) ?? 99
}

private func methodColor(_ method: String) -> Color {
    switch method {
    case "GET": .blue
    case "POST": .green
    case "PUT": .orange
    case "DELETE": .red
    default: .secondary
    }
}

private let friendlyActionNames = [
    "start_vm": "Start", "stop_vm": "Stop", "shutdown_vm": "Shut Down", "reboot_vm": "Restart",
    "suspend_vm": "Suspend", "resume_vm": "Resume", "reset_vm": "Reset",
    "destroy_vm": "Delete", "clone_vm": "Clone", "migrate_vm": "Migrate",
    "snapshot": "Create Snapshot", "delsnapshot": "Delete Snapshot", "rollback": "Restore Snapshot",
    "update_vm": "Save Settings", "vm_config": "Configuration", "resize_vm": "Resize Disk",
    "move_disk": "Move Disk", "vzdump": "Back Up", "create": "Create", "update": "Save Changes",
    "delete": "Delete", "index": "View", "status": "Status"
]

private func featureName(_ path: String) -> String {
    path.split(separator: "/").last.map { fieldLabel(String($0).replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")) } ?? "Action"
}

private func actionIcon(_ operation: APIOperation) -> String {
    let title = operation.title.lowercased()
    if title.contains("create") || title.contains("add") { return "plus.circle" }
    if title.contains("delete") || title.contains("remove") { return "trash" }
    if title.contains("start") || title.contains("resume") { return "play.fill" }
    if title.contains("stop") || title.contains("shutdown") { return "power" }
    if title.contains("backup") { return "externaldrive.badge.timemachine" }
    if title.contains("snapshot") { return "camera.filters" }
    if title.contains("migrate") || title.contains("move") { return "arrow.right.circle" }
    if operation.method == "GET" { return "doc.text.magnifyingglass" }
    return "slider.horizontal.3"
}
