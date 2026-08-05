import SwiftUI

enum GuestKind: String {
    case qemu, lxc
    var title: String { self == .qemu ? "Virtual Machine" : "Container" }
    var icon: String { self == .qemu ? "desktopcomputer" : "shippingbox" }
}

struct GuestCreationWizard: View {
    @EnvironmentObject private var model: ProxmoxModel
    @Environment(\.dismiss) private var dismiss
    let kind: GuestKind
    let node: String

    @State private var step = 0
    @State private var vmid = ""
    @State private var name = ""
    @State private var osType = "l26"
    @State private var memory = "2048"
    @State private var cores = "2"
    @State private var sockets = "1"
    @State private var storage = ""
    @State private var diskSize = "32"
    @State private var bridge = "vmbr0"
    @State private var media = ""
    @State private var password = ""
    @State private var startAfterCreation = true
    @State private var unprivileged = true
    @State private var bridges: [String] = ["vmbr0"]
    @State private var mediaChoices: [String] = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private let stepTitles = ["Basics", "Operating System", "Hardware", "Storage & Network", "Review"]

    private var availableStorage: [String] {
        Array(Set(model.storages.filter { $0.node == node }.compactMap { $0.storage ?? $0.name })).sorted()
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    ForEach(stepTitles.indices, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? Color.cyan : Color.secondary.opacity(0.25))
                            .frame(height: 5)
                    }
                }
                Text(stepTitles[step]).font(.headline)
            }

            switch step {
            case 0: basics
            case 1: operatingSystem
            case 2: hardware
            case 3: storageAndNetwork
            default: review
            }
        }
        .navigationTitle("Create \(kind.title)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < stepTitles.count - 1 {
                    Button("Continue") { step += 1 }.buttonStyle(.borderedProminent).disabled(!stepIsValid)
                } else {
                    Button("Create") { Task { await create() } }
                        .buttonStyle(.borderedProminent).disabled(!formIsValid || isCreating)
                }
            }
            .padding().background(.bar)
        }
        .overlay { if isLoading || isCreating { ProgressView(isCreating ? "Creating…" : "Loading…") } }
        .task { await prepare() }
        .task(id: storage) { await loadMedia() }
        .alert("Created", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("Done") { dismiss() }
        } message: { Text(resultMessage ?? "") }
        .alert("Could Not Create", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
    }

    private var basics: some View {
        Section("Identity") {
            LabeledContent("Node", value: node)
            TextField("VM ID", text: $vmid).keyboardType(.numberPad)
            TextField(kind == .qemu ? "Name" : "Hostname", text: $name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Start after creation", isOn: $startAfterCreation)
        }
    }

    @ViewBuilder private var operatingSystem: some View {
        if kind == .qemu {
            Section("Guest Operating System") {
                Picker("Type", selection: $osType) {
                    Text("Linux 2.6+ Kernel").tag("l26")
                    Text("Linux 2.4 Kernel").tag("l24")
                    Text("Microsoft Windows 11 / 2025").tag("win11")
                    Text("Microsoft Windows 10 / 2016 / 2019").tag("win10")
                    Text("Microsoft Windows 8 / 2012").tag("win8")
                    Text("Microsoft Windows 7 / 2008 R2").tag("win7")
                    Text("Other").tag("other")
                }
                Picker("Installation Media", selection: $media) {
                    Text("No media").tag("")
                    ForEach(mediaChoices, id: \.self) { Text(shortVolumeName($0)).tag($0) }
                }
                if mediaChoices.isEmpty {
                    Label("No ISO images were found on \(storage). You can create the VM without media and attach one later.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            Section("Container Template") {
                Picker("Template", selection: $media) {
                    if mediaChoices.isEmpty { Text("No templates found").tag("") }
                    ForEach(mediaChoices, id: \.self) { Text(shortVolumeName($0)).tag($0) }
                }
                if mediaChoices.isEmpty {
                    Label("Download a container template to this storage before creating a container.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                SecureField("Root password (optional)", text: $password)
                Toggle("Unprivileged container", isOn: $unprivileged)
            }
        }
    }

    private var hardware: some View {
        Section("CPU & Memory") {
            TextField("CPU cores", text: $cores).keyboardType(.numberPad)
            if kind == .qemu { TextField("Sockets", text: $sockets).keyboardType(.numberPad) }
            TextField("Memory (MiB)", text: $memory).keyboardType(.numberPad)
        }
    }

    private var storageAndNetwork: some View {
        Group {
            Section("Storage") {
                Picker("Storage", selection: $storage) {
                    ForEach(availableStorage, id: \.self) { Text($0).tag($0) }
                }
                TextField("Disk size (GiB)", text: $diskSize).keyboardType(.decimalPad)
            }
            Section("Network") {
                Picker("Bridge", selection: $bridge) {
                    ForEach(bridges, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Firewall", value: "Enabled")
                if kind == .lxc { LabeledContent("IPv4", value: "DHCP") }
            }
        }
    }

    private var review: some View {
        Group {
            Section("Identity") {
                LabeledContent("Type", value: kind.title)
                LabeledContent("Node", value: node)
                LabeledContent("ID", value: vmid)
                LabeledContent(kind == .qemu ? "Name" : "Hostname", value: name.isEmpty ? "Not set" : name)
            }
            Section("Configuration") {
                LabeledContent("CPU", value: kind == .qemu ? "\(sockets) socket · \(cores) cores" : "\(cores) cores")
                LabeledContent("Memory", value: "\(memory) MiB")
                LabeledContent("Disk", value: "\(diskSize) GiB on \(storage)")
                LabeledContent("Network", value: bridge)
                LabeledContent("Start automatically", value: startAfterCreation ? "Yes" : "No")
            }
            Section {
                Text("Proxmox will validate the complete configuration before starting the creation task.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var stepIsValid: Bool {
        switch step {
        case 0: return Int(vmid) != nil && !vmid.isEmpty
        case 1: return kind == .qemu || !media.isEmpty
        case 2: return Int(cores) != nil && Int(memory) != nil && (kind == .lxc || Int(sockets) != nil)
        case 3: return !storage.isEmpty && Double(diskSize) != nil && !bridge.isEmpty
        default: return formIsValid
        }
    }

    private var formIsValid: Bool {
        Int(vmid) != nil && Int(cores) != nil && Int(memory) != nil && Double(diskSize) != nil &&
        !storage.isEmpty && !bridge.isEmpty && (kind == .qemu || !media.isEmpty)
    }

    private func prepare() async {
        isLoading = true
        defer { isLoading = false }
        if storage.isEmpty { storage = availableStorage.first ?? "" }
        do {
            vmid = try await model.endpoint("cluster/nextid").text
            if case .array(let networks) = try await model.endpoint("nodes/\(node)/network") {
                let names = networks.compactMap { value -> String? in
                    guard case .object(let object) = value else { return nil }
                    let iface = object["iface"]?.text ?? ""
                    let type = object["type"]?.text ?? object["type_text"]?.text ?? ""
                    return type.localizedCaseInsensitiveContains("bridge") || iface.hasPrefix("vmbr") ? iface : nil
                }
                if !names.isEmpty { bridges = Array(Set(names)).sorted(); bridge = bridges.first ?? "vmbr0" }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadMedia() async {
        guard !storage.isEmpty else { return }
        do {
            let content = kind == .qemu ? "iso" : "vztmpl"
            guard case .array(let items) = try await model.endpoint(
                "nodes/\(node)/storage/\(storage)/content", query: ["content": content]
            ) else { return }
            mediaChoices = items.compactMap { item in
                guard case .object(let object) = item else { return nil }
                return object["volid"]?.text
            }.sorted()
            if kind == .lxc, !mediaChoices.contains(media) { media = mediaChoices.first ?? "" }
        } catch { mediaChoices = [] }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        var form: [String: String] = [
            "vmid": vmid, "memory": memory, "cores": cores, "start": startAfterCreation ? "1" : "0"
        ]
        if kind == .qemu {
            if !name.isEmpty { form["name"] = name }
            form["sockets"] = sockets
            form["ostype"] = osType
            form["scsihw"] = "virtio-scsi-pci"
            form["scsi0"] = "\(storage):\(diskSize)"
            form["net0"] = "virtio,bridge=\(bridge),firewall=1"
            if !media.isEmpty { form["ide2"] = "\(media),media=cdrom" }
        } else {
            if !name.isEmpty { form["hostname"] = name }
            form["ostemplate"] = media
            form["rootfs"] = "\(storage):\(diskSize)"
            form["net0"] = "name=eth0,bridge=\(bridge),ip=dhcp,firewall=1"
            form["unprivileged"] = unprivileged ? "1" : "0"
            if !password.isEmpty { form["password"] = password }
        }
        do {
            let result = try await model.operation(method: "POST", path: "nodes/\(node)/\(kind.rawValue)", form: form)
            resultMessage = result.text.hasPrefix("UPID:")
                ? "Creation started. You can follow it in Tasks."
                : "The \(kind.title.lowercased()) was created successfully."
            await model.refresh()
        } catch { errorMessage = error.localizedDescription }
    }
}

private func shortVolumeName(_ volume: String) -> String {
    volume.split(separator: "/").last.map(String.init) ?? volume
}
