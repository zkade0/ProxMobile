import SwiftUI

struct DiskListView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let node: String
    @State private var disks: [ProxmoxDisk] = []
    @State private var isLoading = false

    var body: some View {
        List(disks) { disk in
            NavigationLink { DiskDetailView(node: node, disk: disk) } label: {
                HStack(spacing: 12) {
                    Image(systemName: disk.isPartition ? "square.split.bottomrightquarter" : "internaldrive")
                        .font(.title2).foregroundStyle(disk.healthColor).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(disk.deviceName).font(.headline.monospaced())
                        Text(disk.identity).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(disk.sizeText)
                            if !disk.used.isEmpty { Text(disk.used) }
                            if disk.mounted { Label("Mounted", systemImage: "checkmark.circle") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !disk.health.isEmpty {
                        Text(disk.health.capitalized).font(.caption.bold()).foregroundStyle(disk.healthColor)
                    }
                }.padding(.vertical, 4)
            }
        }
        .navigationTitle("Disks")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView() }
            else if disks.isEmpty { ContentUnavailableView("No Disks", systemImage: "internaldrive") }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            guard case .array(let values) = try await model.endpoint("nodes/\(node)/disks/list") else { return }
            disks = values.compactMap(ProxmoxDisk.init).sorted {
                $0.devpath.localizedStandardCompare($1.devpath) == .orderedAscending
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct DiskDetailView: View {
    let node: String
    let disk: ProxmoxDisk

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(disk.deviceName).font(.title2.bold().monospaced())
                        Text(disk.identity).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: disk.isPartition ? "square.split.bottomrightquarter" : "internaldrive")
                        .font(.largeTitle).foregroundStyle(disk.healthColor)
                }
            }
            Section("Device") {
                LabeledContent("Path", value: disk.devpath)
                LabeledContent("Size", value: disk.sizeText)
                if !disk.vendor.isEmpty { LabeledContent("Vendor", value: disk.vendor) }
                if !disk.model.isEmpty { LabeledContent("Model", value: disk.model) }
                if !disk.serial.isEmpty { LabeledContent("Serial", value: disk.serial) }
                if !disk.wwn.isEmpty { LabeledContent("World Wide Name", value: disk.wwn) }
                if !disk.parent.isEmpty { LabeledContent("Parent Disk", value: disk.parent) }
            }
            Section("Status") {
                LabeledContent("Health", value: disk.health.isEmpty ? "Not reported" : disk.health.capitalized)
                LabeledContent("Usage", value: disk.used.isEmpty ? "Unused" : disk.used)
                LabeledContent("Mounted", value: disk.mounted ? "Yes" : "No")
                LabeledContent("Partition Table", value: disk.gpt ? "GPT" : "Not detected")
                if disk.osdID >= 0 { LabeledContent("Ceph OSD", value: String(disk.osdID)) }
            }
            if !disk.isPartition {
                Section("Diagnostics") {
                    NavigationLink { DiskSMARTView(node: node, path: disk.devpath) } label: {
                        Label("SMART Details", systemImage: "heart.text.square")
                    }
                }
            }
        }
        .navigationTitle(disk.deviceName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiskSMARTView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let node: String
    let path: String
    @State private var values: [String: JSONValue] = [:]
    @State private var isLoading = false

    var body: some View {
        List {
            ForEach(values.keys.sorted(), id: \.self) { key in
                if let value = values[key] {
                    LabeledContent(friendlyDiskLabel(key), value: value.text.isEmpty ? "—" : value.text)
                }
            }
        }
        .navigationTitle("SMART Details")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            if case .object(let object) = try await model.endpoint("nodes/\(node)/disks/smart", query: ["disk": path]) {
                values = object
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct ProxmoxDisk: Identifiable {
    let devpath: String
    let model: String
    let vendor: String
    let serial: String
    let wwn: String
    let size: Double
    let used: String
    let health: String
    let mounted: Bool
    let gpt: Bool
    let parent: String
    let osdID: Int
    var id: String { devpath }
    var deviceName: String { URL(fileURLWithPath: devpath).lastPathComponent }
    var isPartition: Bool { !parent.isEmpty }
    var identity: String {
        let name = [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? devpath : name
    }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .decimal) }
    var healthColor: Color {
        switch health.lowercased() {
        case "passed", "ok": .green
        case "unknown", "": .secondary
        default: .orange
        }
    }

    init?(_ value: JSONValue) {
        guard case .object(let object) = value, let devpath = object["devpath"]?.text, !devpath.isEmpty else { return nil }
        self.devpath = devpath
        model = object["model"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        vendor = object["vendor"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        serial = object["serial"]?.text ?? ""
        wwn = object["wwn"]?.text ?? ""
        size = Double(object["size"]?.text ?? "") ?? 0
        used = object["used"]?.text ?? ""
        health = object["health"]?.text ?? ""
        mounted = ["1", "true"].contains(object["mounted"]?.text.lowercased() ?? "")
        gpt = ["1", "true"].contains(object["gpt"]?.text.lowercased() ?? "")
        parent = object["parent"]?.text ?? ""
        osdID = Int(object["osdid"]?.text ?? "") ?? -1
    }
}

private func friendlyDiskLabel(_ key: String) -> String {
    key.replacingOccurrences(of: "_", with: " ").capitalized
}
