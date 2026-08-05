import SwiftUI

struct SnapshotManagerView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let resource: ProxmoxResource
    @State private var snapshots: [SnapshotEntry] = []
    @State private var isLoading = false
    @State private var showingCreate = false
    @State private var name = ""
    @State private var description = ""
    @State private var includeMemory = false
    @State private var pendingDelete: SnapshotEntry?
    @State private var pendingRollback: SnapshotEntry?

    private var base: String { "nodes/\(resource.node ?? "")/\(resource.type)/\(resource.vmid ?? 0)/snapshot" }

    var body: some View {
        List {
            ForEach(snapshots) { snapshot in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: snapshot.name == "current" ? "play.circle" : "camera.filters").foregroundStyle(.cyan)
                        Text(snapshot.name == "current" ? "Current State" : snapshot.name).font(.headline)
                        Spacer()
                        if snapshot.includesMemory { Image(systemName: "memorychip").foregroundStyle(.secondary) }
                    }
                    if !snapshot.description.isEmpty { Text(snapshot.description).font(.caption).foregroundStyle(.secondary) }
                    if let date = snapshot.date { Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary) }
                }
                .swipeActions(edge: .trailing) {
                    if snapshot.name != "current" {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = snapshot }
                    }
                }
                .swipeActions(edge: .leading) {
                    if snapshot.name != "current" {
                        Button("Restore", systemImage: "arrow.uturn.backward") { pendingRollback = snapshot }.tint(.orange)
                    }
                }
            }
        }
        .navigationTitle("Snapshots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Create snapshot", systemImage: "plus") { showingCreate = true } }
        }
        .overlay {
            if isLoading { ProgressView() }
            else if snapshots.isEmpty { ContentUnavailableView("No Snapshots", systemImage: "camera.filters") }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                Form {
                    TextField("Snapshot name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                    if resource.type == "qemu" { Toggle("Include virtual machine memory", isOn: $includeMemory) }
                }
                .navigationTitle("New Snapshot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingCreate = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }.disabled(name.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Restore \(pendingRollback?.name ?? "snapshot")?", isPresented: Binding(get: { pendingRollback != nil }, set: { if !$0 { pendingRollback = nil } }), titleVisibility: .visible) {
            if let snapshot = pendingRollback {
                Button("Restore Snapshot") { Task { await rollback(snapshot) } }
            }
            Button("Cancel", role: .cancel) { pendingRollback = nil }
        } message: { Text("The guest will return to this snapshot. Current changes may be lost.") }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "snapshot")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let snapshot = pendingDelete {
                Button("Delete Snapshot", role: .destructive) { Task { await delete(snapshot) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard case .array(let values) = try await model.endpoint(base) else { return }
            snapshots = values.compactMap(SnapshotEntry.init).sorted { ($0.timestamp ?? .greatestFiniteMagnitude) > ($1.timestamp ?? .greatestFiniteMagnitude) }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func create() async {
        showingCreate = false; isLoading = true
        defer { isLoading = false }
        do {
            var form = ["snapname": name]
            if !description.isEmpty { form["description"] = description }
            if includeMemory { form["vmstate"] = "1" }
            _ = try await model.operation(method: "POST", path: base, form: form)
            name = ""; description = ""; includeMemory = false
            await load()
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func rollback(_ snapshot: SnapshotEntry) async {
        pendingRollback = nil; isLoading = true
        defer { isLoading = false }
        do { _ = try await model.operation(method: "POST", path: "\(base)/\(encoded(snapshot.name))/rollback", form: [:]); await model.refresh() }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func delete(_ snapshot: SnapshotEntry) async {
        pendingDelete = nil; isLoading = true
        defer { isLoading = false }
        do { _ = try await model.operation(method: "DELETE", path: "\(base)/\(encoded(snapshot.name))", form: [:]); await load() }
        catch { model.errorMessage = error.localizedDescription }
    }
}

private struct SnapshotEntry: Identifiable {
    let name: String
    let description: String
    let timestamp: Double?
    let includesMemory: Bool
    var id: String { name }
    var date: Date? { timestamp.map(Date.init(timeIntervalSince1970:)) }

    init?(_ value: JSONValue) {
        guard case .object(let object) = value, let name = object["name"]?.text else { return nil }
        self.name = name
        description = object["description"]?.text ?? ""
        timestamp = object["snaptime"].flatMap { Double($0.text) }
        includesMemory = object["vmstate"]?.text == "1"
    }
}

struct CloneGuestView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @Environment(\.dismiss) private var dismiss
    let resource: ProxmoxResource
    @State private var newID = ""
    @State private var name = ""
    @State private var target = ""
    @State private var storage = ""
    @State private var fullClone = true
    @State private var isRunning = false

    var body: some View {
        Form {
            Section("New Guest") {
                TextField("New ID", text: $newID).keyboardType(.numberPad)
                TextField("Name", text: $name)
                Picker("Target node", selection: $target) {
                    ForEach(model.nodes.compactMap(\.node), id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Storage") {
                Toggle("Full clone", isOn: $fullClone)
                Picker("Target storage", selection: $storage) {
                    Text("Same as source").tag("")
                    ForEach(Array(Set(model.storages.compactMap { $0.storage ?? $0.name })).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            Section { Button("Clone", systemImage: "plus.square.on.square") { Task { await clone() } }.disabled(newID.isEmpty || target.isEmpty || isRunning) }
        }
        .navigationTitle("Clone \(resource.title)")
        .overlay { if isRunning { ProgressView("Starting clone…") } }
        .task {
            target = resource.node ?? model.nodes.first?.node ?? ""
            newID = (try? await model.endpoint("cluster/nextid").text) ?? ""
        }
    }

    private func clone() async {
        isRunning = true; defer { isRunning = false }
        var form = ["newid": newID, "target": target, "full": fullClone ? "1" : "0"]
        if !name.isEmpty { form["name"] = name }
        if !storage.isEmpty { form["storage"] = storage }
        do {
            _ = try await model.operation(method: "POST", path: guestBase(resource) + "/clone", form: form)
            await model.refresh(); dismiss()
        } catch { model.errorMessage = error.localizedDescription }
    }
}

struct MigrateGuestView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @Environment(\.dismiss) private var dismiss
    let resource: ProxmoxResource
    @State private var target = ""
    @State private var targetStorage = ""
    @State private var online = true
    @State private var withLocalDisks = true
    @State private var isRunning = false

    private var targets: [String] { model.nodes.compactMap(\.node).filter { $0 != resource.node } }

    var body: some View {
        Form {
            Section("Destination") {
                Picker("Target node", selection: $target) { ForEach(targets, id: \.self) { Text($0).tag($0) } }
                Picker("Target storage", selection: $targetStorage) {
                    Text("Keep storage mapping").tag("")
                    ForEach(Array(Set(model.storages.filter { target.isEmpty || $0.node == target }.compactMap { $0.storage ?? $0.name })).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Options") {
                Toggle("Live migration", isOn: $online).disabled(!resource.isRunning)
                Toggle("Include local disks", isOn: $withLocalDisks)
            }
            Section { Button("Migrate", systemImage: "arrow.right.circle") { Task { await migrate() } }.disabled(target.isEmpty || isRunning) }
        }
        .navigationTitle("Migrate \(resource.title)")
        .overlay { if isRunning { ProgressView("Starting migration…") } }
        .task { target = targets.first ?? ""; online = resource.isRunning }
    }

    private func migrate() async {
        isRunning = true; defer { isRunning = false }
        var form = ["target": target, "online": online ? "1" : "0", "with-local-disks": withLocalDisks ? "1" : "0"]
        if !targetStorage.isEmpty { form["targetstorage"] = targetStorage }
        do {
            _ = try await model.operation(method: "POST", path: guestBase(resource) + "/migrate", form: form)
            await model.refresh(); dismiss()
        } catch { model.errorMessage = error.localizedDescription }
    }
}

struct BackupGuestView: View {
    @EnvironmentObject private var model: ProxmoxModel
    @Environment(\.dismiss) private var dismiss
    let resource: ProxmoxResource
    @State private var storage = ""
    @State private var mode = "snapshot"
    @State private var compression = "zstd"
    @State private var protectedBackup = false
    @State private var notes = ""
    @State private var isRunning = false

    private var storageNames: [String] {
        Array(Set(model.storages.filter { $0.node == resource.node }.compactMap { $0.storage ?? $0.name })).sorted()
    }

    var body: some View {
        Form {
            Section("Destination") {
                Picker("Storage", selection: $storage) { ForEach(storageNames, id: \.self) { Text($0).tag($0) } }
                Picker("Mode", selection: $mode) {
                    Text("Snapshot").tag("snapshot"); Text("Suspend").tag("suspend"); Text("Stop").tag("stop")
                }
                Picker("Compression", selection: $compression) {
                    Text("Zstandard").tag("zstd"); Text("LZO").tag("lzo"); Text("Gzip").tag("gzip"); Text("None").tag("0")
                }
            }
            Section("Options") {
                Toggle("Protect this backup", isOn: $protectedBackup)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            Section { Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") { Task { await backup() } }.disabled(storage.isEmpty || isRunning) }
        }
        .navigationTitle("Back Up \(resource.title)")
        .overlay { if isRunning { ProgressView("Starting backup…") } }
        .task { storage = storageNames.first ?? "" }
    }

    private func backup() async {
        isRunning = true; defer { isRunning = false }
        var form = ["vmid": String(resource.vmid ?? 0), "storage": storage, "mode": mode, "compress": compression]
        if protectedBackup { form["protected"] = "1" }
        if !notes.isEmpty { form["notes-template"] = notes }
        do {
            _ = try await model.operation(method: "POST", path: "nodes/\(resource.node ?? "")/vzdump", form: form)
            await model.refresh(); dismiss()
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private func guestBase(_ resource: ProxmoxResource) -> String {
    "nodes/\(resource.node ?? "")/\(resource.type)/\(resource.vmid ?? 0)"
}

private func encoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}
