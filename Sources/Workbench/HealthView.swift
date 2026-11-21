import AppKit
import SwiftUI
import WorkbenchCore

struct HealthView: View {
    let model: HealthModel
    let space: SpaceModel
    @State private var showingSpace = CommandLine.arguments.contains("--show-space")

    var body: some View {
        if showingSpace {
            SpaceView(model: space) { showingSpace = false }
                .onAppear { space.scanIfNeeded() }
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    summary
                    if model.hasBattery { batteryCard }
                    storageCard
                    memoryCard
                    cpuCard
                    backupCard
                    uptimeCard
                }
                .padding(12)
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: model.overall.symbol)
                .font(.system(size: 26))
                .foregroundStyle(model.overall.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryTitle).font(.title3.weight(.semibold))
                Text("\(model.chip) · \(model.osVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var summaryTitle: String {
        let attention = model.allAssessments.filter { $0.verdict == .act || $0.verdict == .watch }.count
        switch model.overall {
        case .good: return "Your Mac is healthy"
        case .unknown: return "Checking your Mac…"
        case .watch, .act: return attention == 1 ? "1 thing to look at" : "\(attention) things to look at"
        }
    }

    // MARK: Cards

    private var batteryCard: some View {
        Card(title: "Battery", symbol: "battery.75percent", assessment: model.batteryAssessment) {
            if let b = model.battery {
                Headline(value: Format.percent(b.healthPercent), caption: "of original capacity")
                Meter(fraction: b.healthPercent / 100, tint: model.batteryAssessment?.verdict.color ?? .green)
                VStack(spacing: 4) {
                    DetailRow(label: "Charge", value: [b.chargePercent.map { "\($0)%" }, b.statusText]
                        .compactMap { $0 }.joined(separator: " · "))
                    DetailRow(label: "Charge cycles",
                              value: b.designCycleCount.map { "\(b.cycleCount) of \($0)" } ?? "\(b.cycleCount)")
                    if let t = b.temperatureC {
                        DetailRow(label: "Temperature", value: String(format: "%.0f °C", t))
                    }
                    DetailRow(label: "Capacity", value: "\(b.rawMaxCapacity) / \(b.designCapacity) mAh")
                }
            }
        }
    }

    private var storageCard: some View {
        Card(title: "Storage", symbol: "internaldrive", assessment: model.storageAssessment) {
            if let s = model.storage {
                Headline(value: Format.bytes(s.available), caption: "free of \(Format.bytes(s.total))")
                Meter(fraction: s.usedFraction, tint: model.storageAssessment?.verdict.color ?? .accentColor)
                VStack(spacing: 4) {
                    DetailRow(label: "Used", value: "\(Format.bytes(s.used)) (\(Format.percent(s.usedFraction * 100)))")
                    DetailRow(label: "SSD health check", value: s.smartStatus.label)
                }
                Button {
                    showingSpace = true
                    space.scanIfNeeded()
                } label: {
                    Label("What's using space?", systemImage: "magnifyingglass")
                }
                .buttonStyle(.link)
                .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var memoryCard: some View {
        Card(title: "Memory", symbol: "memorychip", assessment: model.memoryAssessment) {
            if let m = model.memory {
                Headline(value: Format.memory(m.used), caption: "used of \(Format.memory(m.total))")
                Meter(fraction: m.usedFraction, tint: model.memoryAssessment?.verdict.color ?? .accentColor)
                VStack(spacing: 4) {
                    DetailRow(label: "Pressure", value: m.pressure.label)
                    DetailRow(label: "Swap used", value: Format.memory(m.swapUsed))
                    DetailRow(label: "Cached files", value: Format.memory(m.cachedFiles))
                }
                TopAppsList(title: "Using the most memory", apps: model.topMemoryApps) { Format.memory($0.memoryBytes) }
            }
        }
    }

    private var cpuCard: some View {
        Card(title: "CPU & temperature", symbol: "cpu", assessment: model.thermalAssessment) {
            if let c = model.cpu {
                Headline(value: c.usagePercent.map { Format.percent($0) } ?? "–", caption: "CPU · \(c.thermal.label)")
                Meter(fraction: (c.usagePercent ?? 0) / 100, tint: model.thermalAssessment?.verdict.color ?? .accentColor)
                DetailRow(label: "Load (1 / 5 / 15 min)",
                          value: String(format: "%.1f / %.1f / %.1f", c.loadAverage.one, c.loadAverage.five,
                                        c.loadAverage.fifteen))
                TopAppsList(title: "Using the most CPU", apps: model.topCPUApps) { Format.percent($0.cpuPercent) }
            }
        }
    }

    private var backupCard: some View {
        Card(title: "Backups", symbol: "clock.arrow.circlepath", assessment: model.backupAssessment) {
            HStack {
                if model.backup == nil {
                    ProgressView().controlSize(.small)
                    Text("Checking Time Machine…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.backup == .noAccess ? "Grant access…" : "Open Time Machine settings") {
                    let pane = model.backup == .noAccess
                        ? "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                        : "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    private var uptimeCard: some View {
        Card(title: "Since last restart", symbol: "power", assessment: model.uptimeAssessment) {
            if let up = model.uptime {
                Headline(value: Format.duration(up), caption: "uptime")
            }
        }
    }
}
