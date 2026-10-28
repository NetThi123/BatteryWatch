import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    @State private var sinceUnplugged = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var keepHistory = HistoryLog.isEnabled

    var body: some View {
        VStack(spacing: 12) {
            if let s = monitor.latest {
                header(s)
                tiles(s)
                let issues = monitor.diagnosis()
                if !issues.isEmpty { issuesCard(issues) }
                detailsCard(s)
                energySection
            } else {
                ProgressView().padding(40)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private func header(_ s: BatterySample) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(s.percent)%")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text(s.onBattery ? "On Battery" : (s.isCharging ? "Charging" : "Plugged In"))
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle(s))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Open Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Button("Open History Folder") { NSWorkspace.shared.open(monitor.log.dir) }
                Toggle("Keep History (\(HistoryLog.retentionDays) days)", isOn: $keepHistory)
                    .onChange(of: keepHistory) { on in
                        if !on { monitor.log.logEvent("History turned off") }
                        HistoryLog.isEnabled = on
                        if on { monitor.log.logEvent("History turned on") }
                        monitor.sample()
                    }
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.setEnabled($0) }
                Divider()
                Button("Quit BatteryWatch") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glass(Circle())
        }
    }

    private func subtitle(_ s: BatterySample) -> String {
        if s.onBattery {
            if let w = monitor.averageWatts(minutes: 10), w > 0.5 {
                return "\(formatDuration(s.remainingWh / w * 3600)) left at current use"
            }
            return "Estimating…"
        }
        if let m = s.timeRemainingMin, s.isCharging { return "Full in \(formatDuration(Double(m) * 60))" }
        return "Health \(Int(monitor.healthPercent.rounded()))%"
    }

    // MARK: Tiles

    private func tiles(_ s: BatterySample) -> some View {
        let watts = s.onBattery ? (monitor.averageWatts(minutes: 3) ?? s.watts) : abs(s.watts)
        let drain = monitor.drainPercentPerHour(minutes: 60)
        return HStack(spacing: 8) {
            Tile(icon: s.onBattery ? "bolt.fill" : "powerplug.fill",
                 value: String(format: "%.1f W", watts),
                 caption: s.onBattery ? "Using" : "Charging",
                 tint: s.onBattery && watts > 15 ? .orange : nil)
            Tile(icon: "chart.line.downtrend.xyaxis",
                 value: drain.map { String(format: "%.1f%%", $0) } ?? "—",
                 caption: "Per hour",
                 tint: (drain ?? 0) > 15 ? .orange : nil)
            Tile(icon: "moon.zzz.fill",
                 value: monitor.lastSleepRate.map { String(format: "%.1f%%", $0) } ?? "—",
                 caption: "Asleep / hr",
                 tint: (monitor.lastSleepRate ?? 0) > 1.5 ? .orange : nil)
        }
    }

    // MARK: Cards

    private func issuesCard(_ issues: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(issues, id: \.self) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.system(size: 12, weight: .semibold))
                        Text(issue.tip).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 16))
    }

    private func detailsCard(_ s: BatterySample) -> some View {
        VStack(spacing: 8) {
            Row(icon: "heart.text.square", label: "Health",
                value: "\(s.fullChargeCapacity) / \(s.designCapacity) mAh",
                trailing: "\(Int(monitor.healthPercent.rounded()))%")
            Row(icon: "arrow.triangle.2.circlepath", label: "Cycles", value: "\(s.cycleCount)")
            Row(icon: "thermometer.medium", label: "Temperature",
                value: Measurement(value: s.temperatureC, unit: UnitTemperature.celsius)
                    .formatted(.measurement(width: .abbreviated, usage: .weather,
                                            numberFormatStyle: .number.precision(.fractionLength(0)))),
                tint: s.temperatureC >= 40 || (s.isCharging && s.temperatureC >= Monitor.hotChargingC) ? .orange : nil)
            if let h = monitor.highChargeHours {
                Row(icon: "battery.100percent", label: "Above 90% (24h)",
                    value: h < 1 / 60 ? "None" : formatDuration(h * 3600),
                    tint: h >= Monitor.highChargeHoursWarn ? .orange : nil)
            }
            Button {
                NSWorkspace.shared.open(Battery.chargeLimitSettingsURL)
            } label: {
                Row(icon: "slider.horizontal.3", label: "Charge Limit", value: "Change in Settings", chevron: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if s.onBattery, let u = monitor.unplugged {
                Row(icon: "powerplug", label: u.observed ? "Unplugged" : "Watching since",
                    value: "\(formatDuration(Date().timeIntervalSince(u.date))) ago at \(u.percent)%")
            }
            if let r = monitor.lastSleepReport {
                Row(icon: "moon.zzz", label: "Last sleep", value: r)
            }
            Divider().padding(.vertical, 2)
            Row(icon: "cup.and.saucer", label: "Kept awake by",
                value: monitor.blockers.isEmpty ? "Nothing" : "\(monitor.blockers.count) process\(monitor.blockers.count == 1 ? "" : "es")")
            ForEach(monitor.blockers.prefix(3), id: \.self) { b in
                Text(b)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)
            }
        }
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Energy

    private var energyRows: [(name: String, value: String, hot: Bool)] {
        if sinceUnplugged {
            return monitor.sessionCPU.sorted { $0.value > $1.value }.prefix(5)
                .filter { $0.value >= 60 }
                .map { ($0.key, formatDuration($0.value), false) }
        }
        return monitor.topNow.prefix(5).filter { $0.1 >= 10 }
            .map { ($0.0, "\(Int($0.1))%", $0.1 >= Monitor.hogThreshold) }
    }

    private var energySection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Using Energy").font(.system(size: 12, weight: .semibold)).fixedSize()
                Spacer()
                Picker("", selection: $sinceUnplugged) {
                    Text("Now").tag(false)
                    Text("This Charge").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 4)

            let rows = energyRows
            if rows.isEmpty {
                Text("No Apps Using Significant Energy")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glass(Capsule())
            } else {
                VStack(spacing: 7) {
                    ForEach(rows, id: \.name) { row in
                        HStack(spacing: 10) {
                            AppIcon(path: monitor.appPaths[row.name])
                            Text(row.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(row.value)
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(row.hot ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        }
                    }
                }
                .padding(12)
                .glass(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - Components

private struct Tile: View {
    let icon: String
    let value: String
    let caption: String
    var tint: Color?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glass(RoundedRectangle(cornerRadius: 16))
    }
}

private struct Row: View {
    let icon: String
    let label: String
    let value: String
    var trailing: String?
    var tint: Color?
    var chevron = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label).font(.system(size: 12))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(chevron ? .secondary : .primary))
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

private struct AppIcon: View {
    let path: String?
    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private extension View {
    /// Liquid Glass on macOS 26+, a subtle filled card on older systems.
    @ViewBuilder func glass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(Color.primary.opacity(0.06)))
                .overlay(shape.stroke(Color.primary.opacity(0.08)))
        }
    }
}
