import Charts
import SwiftUI

enum HistoryResourceKind {
    case node, guest, storage
}

struct ResourceHistoryView: View {
    @EnvironmentObject private var model: ProxmoxModel
    let title: String
    let basePath: String
    let kind: HistoryResourceKind
    @State private var timeframe: HistoryTimeframe = .day
    @State private var samples: [RRDSample] = []
    @State private var isLoading = false

    init(resource: ProxmoxResource) {
        title = resource.title
        if resource.isGuest {
            basePath = "nodes/\(resource.node ?? "")/\(resource.type)/\(resource.vmid ?? 0)"
            kind = .guest
        } else if resource.type == "storage" {
            basePath = "nodes/\(resource.node ?? "")/storage/\(resource.storage ?? resource.name ?? "")"
            kind = .storage
        } else {
            basePath = "nodes/\(resource.node ?? resource.title)"
            kind = .node
        }
    }

    init(title: String, basePath: String, kind: HistoryResourceKind) {
        self.title = title
        self.basePath = basePath
        self.kind = kind
    }

    var body: some View {
        ScrollView {
            Picker("Range", selection: $timeframe) {
                ForEach(HistoryTimeframe.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            LazyVStack(spacing: 16) {
                ForEach(chartDefinitions(for: kind)) { definition in
                    HistoryChartCard(definition: definition, samples: samples, timeframe: timeframe)
                }
            }
            .padding()
        }
        .navigationTitle("\(title) History")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && samples.isEmpty { ProgressView("Loading history…") }
            else if !isLoading && samples.isEmpty {
                ContentUnavailableView("No Historical Data", systemImage: "chart.xyaxis.line")
            }
        }
        .task(id: timeframe) { await monitor() }
        .refreshable { await load() }
    }

    private func monitor() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await load(showSpinner: false)
        }
    }

    private func load(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        defer { isLoading = false }
        do {
            guard case .array(let values) = try await model.endpoint(
                "\(basePath)/rrddata",
                query: ["timeframe": timeframe.rawValue, "cf": "AVERAGE"]
            ) else { return }
            samples = values.compactMap(RRDSample.init).sorted { $0.time < $1.time }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private enum HistoryTimeframe: String, CaseIterable, Identifiable {
    case hour, day, week, month, year
    var id: Self { self }
    var shortTitle: String {
        switch self { case .hour: "1H"; case .day: "1D"; case .week: "1W"; case .month: "1M"; case .year: "1Y" }
    }
}

private struct RRDSample: Identifiable {
    let time: Date
    let values: [String: Double]
    var id: Date { time }

    init?(_ value: JSONValue) {
        guard case .object(let object) = value,
              let timestamp = Double(object["time"]?.text ?? "") else { return nil }
        time = Date(timeIntervalSince1970: timestamp)
        values = object.reduce(into: [:]) { result, pair in
            if let number = Double(pair.value.text), number.isFinite { result[pair.key] = number }
        }
    }
}

private struct ChartDefinition: Identifiable {
    let title: String
    let metrics: [ChartMetric]
    let unit: ChartUnit
    var id: String { title }
}

private struct ChartMetric: Identifiable {
    let key: String
    let title: String
    let color: Color
    var id: String { key }
}

private enum ChartUnit { case percent, bytes, bytesPerSecond, number }

private struct HistoryChartCard: View {
    let definition: ChartDefinition
    let samples: [RRDSample]
    let timeframe: HistoryTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(definition.title).font(.headline)
            HStack(spacing: 14) {
                ForEach(definition.metrics) { metric in
                    HStack(spacing: 5) {
                        Circle().fill(metric.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(metric.title).font(.caption).foregroundStyle(.secondary)
                            Text(latestValue(for: metric)).font(.caption.bold().monospacedDigit())
                        }
                    }
                }
            }
            Chart {
                ForEach(chartPoints) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value(point.metricTitle, point.value),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(by: .value("Metric", point.metricTitle))
                    .interpolationMethod(.monotone)
                    .lineStyle(.init(lineWidth: 2))
                }
            }
            .chartForegroundStyleScale(
                domain: definition.metrics.map(\.title),
                range: definition.metrics.map(\.color)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(shortValue(number)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: timeframe.axisFormat)
                }
            }
            .frame(height: 180)
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
    }

    private func normalized(_ value: Double) -> Double { definition.unit == .percent ? value * 100 : value }

    private var chartPoints: [HistoryChartPoint] {
        definition.metrics.flatMap { metric in
            var segment = 0
            var previousWasPresent = false
            return samples.compactMap { sample -> HistoryChartPoint? in
                guard let value = sample.values[metric.key] else {
                    previousWasPresent = false
                    return nil
                }
                if !previousWasPresent { segment += 1 }
                previousWasPresent = true
                return HistoryChartPoint(
                    time: sample.time,
                    value: normalized(value),
                    metricTitle: metric.title,
                    series: "\(metric.key)-\(segment)"
                )
            }
        }
    }

    private func latestValue(for metric: ChartMetric) -> String {
        guard let value = samples.lazy.reversed().compactMap({ $0.values[metric.key] }).first else { return "—" }
        return formatted(normalized(value))
    }

    private func formatted(_ value: Double) -> String {
        switch definition.unit {
        case .percent: return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + "%"
        case .bytes: return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
        case .bytesPerSecond: return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s"
        case .number: return value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    private func shortValue(_ value: Double) -> String {
        switch definition.unit {
        case .percent: return "\(Int(value))%"
        case .bytes, .bytesPerSecond: return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
        case .number: return value.formatted(.number.precision(.fractionLength(1)))
        }
    }
}

private struct HistoryChartPoint: Identifiable {
    let time: Date
    let value: Double
    let metricTitle: String
    let series: String
    var id: String { "\(series)-\(time.timeIntervalSince1970)" }
}

private extension HistoryTimeframe {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .hour, .day: return .dateTime.hour()
        case .week, .month: return .dateTime.month(.abbreviated).day()
        case .year: return .dateTime.month(.abbreviated)
        }
    }
}

private func chartDefinitions(for kind: HistoryResourceKind) -> [ChartDefinition] {
    switch kind {
    case .node:
        return [
            .init(title: "CPU & I/O Delay", metrics: [
                .init(key: "cpu", title: "CPU", color: .cyan),
                .init(key: "iowait", title: "I/O Delay", color: .orange)
            ], unit: .percent),
            .init(title: "Memory", metrics: [
                .init(key: "memused", title: "Used", color: .blue),
                .init(key: "memtotal", title: "Total", color: .secondary)
            ], unit: .bytes),
            .init(title: "Network", metrics: [
                .init(key: "netin", title: "Incoming", color: .green),
                .init(key: "netout", title: "Outgoing", color: .purple)
            ], unit: .bytesPerSecond),
            .init(title: "Root Disk", metrics: [
                .init(key: "rootused", title: "Used", color: .orange),
                .init(key: "roottotal", title: "Total", color: .secondary)
            ], unit: .bytes),
            .init(title: "Load Average", metrics: [
                .init(key: "loadavg", title: "Load", color: .indigo)
            ], unit: .number)
        ]
    case .guest:
        return [
            .init(title: "CPU", metrics: [.init(key: "cpu", title: "Usage", color: .cyan)], unit: .percent),
            .init(title: "Memory", metrics: [
                .init(key: "mem", title: "Used", color: .blue),
                .init(key: "maxmem", title: "Total", color: .secondary)
            ], unit: .bytes),
            .init(title: "Network", metrics: [
                .init(key: "netin", title: "Incoming", color: .green),
                .init(key: "netout", title: "Outgoing", color: .purple)
            ], unit: .bytesPerSecond),
            .init(title: "Disk I/O", metrics: [
                .init(key: "diskread", title: "Read", color: .teal),
                .init(key: "diskwrite", title: "Write", color: .orange)
            ], unit: .bytesPerSecond),
            .init(title: "Disk Usage", metrics: [
                .init(key: "disk", title: "Used", color: .orange),
                .init(key: "maxdisk", title: "Total", color: .secondary)
            ], unit: .bytes)
        ]
    case .storage:
        return [
            .init(title: "Storage Usage", metrics: [
                .init(key: "used", title: "Used", color: .purple),
                .init(key: "total", title: "Total", color: .secondary)
            ], unit: .bytes)
        ]
    }
}
