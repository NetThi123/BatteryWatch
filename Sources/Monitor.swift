import Foundation
import Combine

struct Issue: Hashable {
    let title: String
    let tip: String
}

/// Samples the battery and processes on a timer, keeps recent history, and produces a diagnosis.
final class Monitor: ObservableObject {
    static let interval: TimeInterval = 60
    /// A process above this CPU % for `hogSamples` consecutive samples triggers an alert.
    static let hogThreshold = 50.0
    static let hogSamples = 5
    /// Charging above this temperature (°C) speeds up battery wear.
    static let hotChargingC = 35.0
    /// Hours a day at ≥90% charge worth flagging.
    static let highChargeHoursWarn = 8.0

    let log = HistoryLog()
    private(set) var latest: BatterySample?
    private(set) var history: [BatterySample] = []          // last ~3h
    private(set) var topNow: [(String, Double)] = []        // CPU % over last interval, by app name
    private(set) var sessionCPU: [String: Double] = [:]     // CPU seconds since unplugged
    private(set) var unplugged: (date: Date, percent: Int, observed: Bool)?
    private(set) var lastSleepReport: String?
    private(set) var sustainedHogs: [String: Int] = [:]     // name -> consecutive samples over threshold
    private(set) var appPaths: [String: String] = [:]       // grouped name -> .app path, for icons
    private(set) var lastSleepRate: Double?                 // %/hr during the last sleep on battery
    private(set) var blockers: [String] = []
    private(set) var highChargeHours: Double?               // hours plugged in at ≥90% over the last 24h
    private var highChargeDate: Date?
    private var appleHealth: (value: Int, date: Date)?

    /// Battery health as System Settings reports it, falling back to our own calculation.
    var healthPercent: Double {
        if appleHealth == nil || Date().timeIntervalSince(appleHealth!.date) > 3600,
           let v = Battery.appleMaximumCapacity() {
            appleHealth = (v, Date())
        }
        return appleHealth.map { Double($0.value) } ?? latest?.healthPercent ?? 0
    }

    private var prevProcs: [Int: ProcessSampler.Entry] = [:]
    private var prevProcDate: Date?
    private var lastAlert: [String: Date] = [:]
    private var sleepStart: BatterySample?

    var onUpdate: (() -> Void)?

    // MARK: - Sampling

    func sample() {
        guard let s = Battery.read() else { return }

        if let prev = latest, prev.externalConnected, s.onBattery {
            unplugged = (s.date, s.percent, true)
            sessionCPU.removeAll()
            log.logEvent("Unplugged at \(s.percent)%")
        } else if latest == nil, s.onBattery {
            unplugged = (s.date, s.percent, false)
        } else if s.externalConnected, latest?.onBattery == true {
            if let u = unplugged {
                log.logEvent("Plugged in at \(s.percent)% after \(formatDuration(s.date.timeIntervalSince(u.date))) on battery (from \(u.percent)%)")
            }
            unplugged = nil
        }

        latest = s
        history.append(s)
        history.removeAll { s.date.timeIntervalSince($0.date) > 3 * 3600 }

        sampleProcesses(onBattery: s.onBattery)
        log.logSample(s, top: topNow)
        if !HistoryLog.isEnabled {
            highChargeHours = nil       // computed from the log, so unavailable without it
            highChargeDate = nil
        } else if highChargeDate == nil || s.date.timeIntervalSince(highChargeDate!) > 600 {
            highChargeHours = log.highChargeSeconds(since: s.date.addingTimeInterval(-24 * 3600)) / 3600
            highChargeDate = s.date
        }
        checkAlerts(s)
        objectWillChange.send()
        onUpdate?()
    }

    private func sampleProcesses(onBattery: Bool) {
        let now = Date()
        let procs = ProcessSampler.snapshot()
        defer { prevProcs = procs; prevProcDate = now }
        guard let prevDate = prevProcDate else { return }
        let elapsed = now.timeIntervalSince(prevDate)
        guard elapsed > 1 else { return }

        var byName: [String: Double] = [:]
        for (pid, e) in procs {
            guard let old = prevProcs[pid] else { continue }
            let delta = e.cpuSeconds - old.cpuSeconds
            if delta > 0 { byName[e.name, default: 0] += delta }
            if let app = e.appPath { appPaths[e.name] = app }
        }
        if onBattery {
            for (name, secs) in byName { sessionCPU[name, default: 0] += secs }
        }
        topNow = byName.map { ($0.key, $0.value / elapsed * 100) }.sorted { $0.1 > $1.1 }

        var hogs: [String: Int] = [:]
        for (name, pct) in topNow where pct >= Monitor.hogThreshold {
            hogs[name] = (sustainedHogs[name] ?? 0) + 1
        }
        sustainedHogs = hogs
    }

    private func checkAlerts(_ s: BatterySample) {
        for (name, count) in sustainedHogs where count >= Monitor.hogSamples && shouldAlert(name) {
            lastAlert[name] = Date()
            let pct = Int(topNow.first { $0.0 == name }?.1 ?? 0)
            let tip = Advice.forProcess(name) ?? "Quit it or check it in Activity Monitor."
            notify("BatteryWatch: \(name) is draining battery", "\(pct)% CPU for \(count)+ min. \(tip)")
            log.logEvent("ALERT \(name) at \(pct)% CPU for \(count) samples")
        }
        if s.onBattery, let w = averageWatts(minutes: 10), w > 20, shouldAlert("__watts") {
            lastAlert["__watts"] = Date()
            notify("BatteryWatch: high power draw", String(format: "Averaging %.1f W over 10 min.", w))
        }
        if s.isCharging, s.temperatureC >= Monitor.hotChargingC, shouldAlert("__heat") {
            lastAlert["__heat"] = Date()
            notify("BatteryWatch: battery is hot while charging",
                   String(format: "%.0f°C. Heat while charging ages the battery fastest. Let it cool or unplug for a while.", s.temperatureC))
            log.logEvent(String(format: "ALERT hot while charging %.1f°C at %d%%", s.temperatureC, s.percent))
        } else if s.temperatureC >= 40, shouldAlert("__heat") {
            lastAlert["__heat"] = Date()
            notify("BatteryWatch: battery is hot", String(format: "%.0f°C. Heavy load or a warm spot; it ages the battery.", s.temperatureC))
            log.logEvent(String(format: "ALERT hot %.1f°C", s.temperatureC))
        }
    }

    private func shouldAlert(_ key: String) -> Bool {
        guard let last = lastAlert[key] else { return true }
        return Date().timeIntervalSince(last) > 2 * 3600
    }

    // MARK: - Sleep tracking

    func willSleep() {
        sleepStart = Battery.read()
        if let s = sleepStart { log.logEvent("Sleep at \(s.percent)%") }
    }

    func didWake() {
        prevProcDate = nil   // don't attribute sleep time to a CPU % interval
        guard let start = sleepStart, let end = Battery.read() else { return }
        sleepStart = nil
        let hours = end.date.timeIntervalSince(start.date) / 3600
        let lost = start.percent - end.percent
        let plugged = start.externalConnected || end.externalConnected
        log.logEvent("Wake at \(end.percent)% after \(formatDuration(hours * 3600)) asleep (lost \(lost)%\(plugged ? ", was plugged in" : ""))")
        guard !plugged, hours > 0.25 else { sample(); return }
        let rate = Double(lost) / hours
        lastSleepRate = rate
        lastSleepReport = String(format: "Lost %d%% in %@", lost, formatDuration(hours * 3600))
        if hours > 0.5 && rate > 1.5 {
            notify("BatteryWatch: battery drained while asleep",
                   String(format: "Lost %d%% in %@. Normal is under ~1%%/hr. Check sleep blockers in the menu.", lost, formatDuration(hours * 3600)))
        }
        sample()
    }

    // MARK: - Derived stats

    func averageWatts(minutes: Double) -> Double? {
        guard let last = latest else { return nil }
        var window: [BatterySample] = []
        for s in history where s.onBattery && last.date.timeIntervalSince(s.date) <= minutes * 60 {
            // The gauge doesn't always refresh between samples; an exact repeat under load is a stale reading.
            if let prev = window.last, s.amperageMA != 0,
               s.amperageMA == prev.amperageMA, s.voltageMV == prev.voltageMV { continue }
            window.append(s)
        }
        guard !window.isEmpty else { return nil }
        return window.map(\.watts).reduce(0, +) / Double(window.count)
    }

    /// Percent per hour lost, measured from the actual charge level over the window.
    func drainPercentPerHour(minutes: Double) -> Double? {
        guard let last = latest, last.onBattery else { return nil }
        // Only use the contiguous on-battery stretch at the end of history.
        var window: [BatterySample] = []
        for s in history.reversed() {
            guard s.onBattery, last.date.timeIntervalSince(s.date) <= minutes * 60 else { break }
            window.insert(s, at: 0)
        }
        guard let first = window.first, last.date.timeIntervalSince(first.date) >= 10 * 60 else { return nil }
        // Use mAh rather than whole percent for precision.
        let usedMAh = Double(first.currentCapacityMAh - last.currentCapacityMAh)
        let hours = last.date.timeIntervalSince(first.date) / 3600
        return usedMAh / Double(max(last.fullChargeCapacity, 1)) * 100 / hours
    }

    func refreshBlockers() {
        blockers = SleepBlockers.current()
        objectWillChange.send()
    }

    func diagnosis() -> [Issue] {
        var out: [Issue] = []
        for (name, count) in sustainedHogs.sorted(by: { $0.value > $1.value }) where count >= 2 {
            let pct = Int(topNow.first { $0.0 == name }?.1 ?? 0)
            out.append(Issue(title: "\(name) at \(pct)% CPU for \(count)+ min",
                             tip: Advice.forProcess(name) ?? "Quit it or check it in Activity Monitor."))
        }
        let uptime = systemUptimeDays()
        if uptime > 7 {
            out.append(Issue(title: "No restart in \(Int(uptime)) days",
                             tip: "Restarting clears stuck background processes."))
        }
        if let w = averageWatts(minutes: 10), w > 15 {
            out.append(Issue(title: String(format: "High draw: %.1f W average", w),
                             tip: "Light use is usually 3–8 W."))
        }
        if let s = latest {
            if s.temperatureC > 40 {
                out.append(Issue(title: String(format: "Battery is warm (%.0f°C)", s.temperatureC),
                                 tip: "Heat means heavy load, and it ages the battery."))
            } else if s.isCharging, s.temperatureC >= Monitor.hotChargingC {
                out.append(Issue(title: String(format: "Charging while warm (%.0f°C)", s.temperatureC),
                                 tip: "Heat while charging ages the battery fastest. Let it cool or unplug for a while."))
            }
            if let h = highChargeHours, h >= Monitor.highChargeHoursWarn {
                out.append(Issue(title: "Held above 90% for \(formatDuration(h * 3600)) in 24h",
                                 tip: "Sitting near full wears the battery. Set an 80% limit under Charge Limit below."))
            }
            if healthPercent < 80 {
                out.append(Issue(title: "Capacity below 80%", tip: "Consider a battery service."))
            }
        }
        if let r = lastSleepRate, r > 1.5 {
            out.append(Issue(title: String(format: "Drained %.1f%%/hr while asleep", r),
                             tip: "Check what's keeping the Mac awake."))
        }
        return out
    }
}

enum Advice {
    static func forProcess(_ name: String) -> String? {
        switch name {
        case "BTLEServer", "bluetoothd":
            return "Bluetooth daemon is stuck. Restart the Mac, or toggle Bluetooth off/on."
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "spotlightknowledged":
            return "Spotlight is indexing. Usually temporary after updates or big file changes."
        case "photoanalysisd", "mediaanalysisd":
            return "Photos is analyzing your library. Temporary; happens faster while plugged in."
        case "WindowServer":
            return "Screen drawing. Lower brightness, close animated windows, or disconnect external displays."
        case "kernel_task":
            return "Usually means the Mac is hot and throttling."
        case "backupd":
            return "Time Machine backup running."
        case _ where name.contains("Chrome") || name.contains("Helper (Renderer)"):
            return "A browser tab is busy. Check Chrome's Task Manager (Window > Task Manager)."
        default:
            return nil
        }
    }
}
