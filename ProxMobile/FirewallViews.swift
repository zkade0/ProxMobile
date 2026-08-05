import SwiftUI

struct FirewallRulesView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let title: String
    let base: String
    @State private var rules: [FirewallRule] = []
    @State private var editing: FirewallRule?
    @State private var showingAdd = false
    @State private var pendingDelete: FirewallRule?
    @State private var isLoading = false

    var body: some View {
        List {
            ForEach(rules) { rule in
                Button { editing = rule } label: {
                    HStack(spacing: 12) {
                        Image(systemName: rule.enabled ? "checkmark.shield.fill" : "shield.slash")
                            .foregroundStyle(rule.enabled ? actionColor(rule.action) : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(rule.direction.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(rule.action).font(.headline)
                                if !rule.protocolName.isEmpty { Text(rule.protocolName.uppercased()).font(.caption.monospaced()) }
                            }
                            Text(rule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if !rule.comment.isEmpty { Text(rule.comment).font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                }.buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = rule }
                }
            }
            .onMove(perform: move)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) { Button("Add rule", systemImage: "plus") { showingAdd = true } }
        }
        .overlay {
            if isLoading { ProgressView() }
            else if rules.isEmpty { ContentUnavailableView("No Firewall Rules", systemImage: "shield") }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingAdd) {
            FirewallRuleEditor(title: "New Rule", initial: nil) { form in await save(form: form, position: nil) }
        }
        .sheet(item: $editing) { rule in
            FirewallRuleEditor(title: "Edit Rule", initial: rule) { form in await save(form: form, position: rule.position) }
        }
        .confirmationDialog("Delete this firewall rule?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let rule = pendingDelete {
                Button("Delete Rule", role: .destructive) { Task { await delete(rule) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            guard case .array(let values) = try await model.endpoint("\(base)/rules") else { return }
            rules = values.compactMap(FirewallRule.init).sorted { $0.position < $1.position }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func save(form: [String: String], position: Int?) async -> Bool {
        do {
            let path = position.map { "\(base)/rules/\($0)" } ?? "\(base)/rules"
            _ = try await model.operation(method: position == nil ? "POST" : "PUT", path: path, form: form)
            showingAdd = false; editing = nil; await load(); return true
        } catch { model.errorMessage = error.localizedDescription; return false }
    }

    private func delete(_ rule: FirewallRule) async {
        pendingDelete = nil
        do { _ = try await model.operation(method: "DELETE", path: "\(base)/rules/\(rule.position)", form: [:]); await load() }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        let rule = rules[sourceIndex]
        let target = destination > sourceIndex ? destination - 1 : destination
        rules.move(fromOffsets: source, toOffset: destination)
        Task {
            do { _ = try await model.operation(method: "PUT", path: "\(base)/rules/\(rule.position)", form: ["moveto": String(target)]) }
            catch { model.errorMessage = error.localizedDescription; await load() }
        }
    }
}

private struct FirewallRule: Identifiable {
    let position: Int
    let direction: String
    let action: String
    let enabled: Bool
    let source: String
    let destination: String
    let protocolName: String
    let sourcePort: String
    let destinationPort: String
    let log: String
    let comment: String
    let macro: String
    var id: Int { position }

    var summary: String {
        var parts: [String] = []
        if !source.isEmpty { parts.append("From \(source)") }
        if !destination.isEmpty { parts.append("To \(destination)") }
        if !sourcePort.isEmpty { parts.append("Source port \(sourcePort)") }
        if !destinationPort.isEmpty { parts.append("Port \(destinationPort)") }
        if !macro.isEmpty { parts.append(macro) }
        return parts.isEmpty ? "Any source and destination" : parts.joined(separator: " · ")
    }

    init?(_ value: JSONValue) {
        guard case .object(let object) = value, let position = object["pos"].flatMap({ Int($0.text) }) else { return nil }
        self.position = position
        direction = object["type"]?.text ?? "in"
        action = object["action"]?.text ?? "ACCEPT"
        enabled = object["enable"]?.text != "0"
        source = object["source"]?.text ?? ""
        destination = object["dest"]?.text ?? ""
        protocolName = object["proto"]?.text ?? ""
        sourcePort = object["sport"]?.text ?? ""
        destinationPort = object["dport"]?.text ?? ""
        log = object["log"]?.text ?? "nolog"
        comment = object["comment"]?.text ?? ""
        macro = object["macro"]?.text ?? ""
    }
}

private struct FirewallRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: ([String: String]) async -> Bool
    @State private var direction: String
    @State private var action: String
    @State private var enabled: Bool
    @State private var source: String
    @State private var destination: String
    @State private var protocolName: String
    @State private var sourcePort: String
    @State private var destinationPort: String
    @State private var log: String
    @State private var comment: String
    @State private var isSaving = false

    init(title: String, initial: FirewallRule?, onSave: @escaping ([String: String]) async -> Bool) {
        self.title = title; self.onSave = onSave
        _direction = State(initialValue: initial?.direction ?? "in")
        _action = State(initialValue: initial?.action ?? "ACCEPT")
        _enabled = State(initialValue: initial?.enabled ?? true)
        _source = State(initialValue: initial?.source ?? "")
        _destination = State(initialValue: initial?.destination ?? "")
        _protocolName = State(initialValue: initial?.protocolName ?? "")
        _sourcePort = State(initialValue: initial?.sourcePort ?? "")
        _destinationPort = State(initialValue: initial?.destinationPort ?? "")
        _log = State(initialValue: initial?.log ?? "nolog")
        _comment = State(initialValue: initial?.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule") {
                    Toggle("Enabled", isOn: $enabled)
                    Picker("Direction", selection: $direction) { Text("Incoming").tag("in"); Text("Outgoing").tag("out") }
                    Picker("Action", selection: $action) { ForEach(["ACCEPT", "DROP", "REJECT"], id: \.self) { Text($0.capitalized).tag($0) } }
                    Picker("Protocol", selection: $protocolName) {
                        Text("Any").tag(""); Text("TCP").tag("tcp"); Text("UDP").tag("udp"); Text("ICMP").tag("icmp")
                    }
                }
                Section("Traffic") {
                    TextField("Source address or alias", text: $source).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Destination address or alias", text: $destination).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if protocolName == "tcp" || protocolName == "udp" {
                        TextField("Source port", text: $sourcePort).keyboardType(.numbersAndPunctuation)
                        TextField("Destination port", text: $destinationPort).keyboardType(.numbersAndPunctuation)
                    }
                }
                Section("Logging & Notes") {
                    Picker("Log level", selection: $log) {
                        Text("Disabled").tag("nolog")
                        ForEach(["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Comment", text: $comment, axis: .vertical).lineLimit(2...4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if isSaving { ProgressView("Saving…") } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(isSaving) }
            }
        }
    }

    private func save() async {
        isSaving = true; defer { isSaving = false }
        var form = ["type": direction, "action": action, "enable": enabled ? "1" : "0", "log": log]
        if !source.isEmpty { form["source"] = source }
        if !destination.isEmpty { form["dest"] = destination }
        if !protocolName.isEmpty { form["proto"] = protocolName }
        if !sourcePort.isEmpty { form["sport"] = sourcePort }
        if !destinationPort.isEmpty { form["dport"] = destinationPort }
        if !comment.isEmpty { form["comment"] = comment }
        if await onSave(form) { dismiss() }
    }
}

private func actionColor(_ action: String) -> Color {
    switch action { case "ACCEPT": .green; case "DROP", "REJECT": .red; default: .orange }
}
