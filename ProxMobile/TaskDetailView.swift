import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let task: ProxmoxTask
    @State private var status: [String: JSONValue] = [:]
    @State private var lines: [TaskLogLine] = []
    @State private var isLoading = false
    @State private var confirmingStop = false

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.headline)
                        Text(displayStatus).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: statusIcon).foregroundStyle(statusColor)
                }
            }
            Section("Details") {
                LabeledContent("Node", value: task.node)
                LabeledContent("User", value: task.user ?? "System")
                if let started = task.started { LabeledContent("Started") { Text(started, format: .dateTime) } }
                if let finished = task.finished { LabeledContent("Finished") { Text(finished, format: .dateTime) } }
                if let started = task.started {
                    LabeledContent("Duration", value: duration(from: started, to: task.finished ?? .now))
                }
            }
            Section("Output") {
                if lines.isEmpty && !isLoading {
                    Text("No output was recorded for this task.").foregroundStyle(.secondary)
                } else {
                    ForEach(lines) { line in
                        Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading && lines.isEmpty { ProgressView() } }
        .toolbar {
            if isStillRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { confirmingStop = true }
                }
            }
        }
        .confirmationDialog("Stop this task?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Task", role: .destructive) { Task { await stop() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Proxmox will interrupt the running operation if it can be stopped safely.") }
        .task { await monitor() }
        .refreshable { await load() }
    }

    private var isStillRunning: Bool { status["status"]?.text == "running" || (status.isEmpty && task.isRunning) }
    private var displayStatus: String { status["exitstatus"]?.text ?? (isStillRunning ? "Running" : task.result) }
    private var statusIcon: String { isStillRunning ? "progress.indicator" : (displayStatus == "OK" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") }
    private var statusColor: Color { isStillRunning ? .cyan : (displayStatus == "OK" ? .green : .orange) }

    private func monitor() async {
        repeat {
            await load()
            if isStillRunning { try? await Task.sleep(for: .seconds(2)) }
        } while isStillRunning && !Task.isCancelled
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            async let statusValue = model.endpoint("nodes/\(task.node)/tasks/\(task.upid)/status")
            async let logValue = model.endpoint("nodes/\(task.node)/tasks/\(task.upid)/log", query: ["limit": "500"])
            if case .object(let object) = try await statusValue { status = object }
            if case .array(let values) = try await logValue { lines = values.compactMap(TaskLogLine.init) }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func stop() async {
        do {
            _ = try await model.operation(method: "DELETE", path: "nodes/\(task.node)/tasks/\(task.upid)", form: [:])
            await load()
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct TaskLogLine: Identifiable {
    let number: Int
    let text: String
    var id: Int { number }

    init?(_ value: JSONValue) {
        guard case .object(let object) = value else { return nil }
        number = Int(object["n"]?.text ?? "") ?? 0
        text = object["t"]?.text ?? ""
    }
}

private func duration(from start: Date, to end: Date) -> String {
    Duration.seconds(max(0, end.timeIntervalSince(start))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
}
