import Foundation

/// Writes history to ~/Library/Application Support/BatteryWatch so drain can be investigated later.
/// Entries older than `retentionDays` are pruned; logging can be turned off from the ⋯ menu.
final class HistoryLog {
    static let retentionDays = 30
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepHistory") }
    }

    let dir: URL
    private let samplesURL: URL
    private let eventsURL: URL
    private let iso = ISO8601DateFormatter()
    private var lastPrune: Date?

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryWatch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        samplesURL = dir.appendingPathComponent("samples.csv")
        eventsURL = dir.appendingPathComponent("events.log")
        iso.formatOptions = [.withInternetDateTime]; iso.timeZone = .current
        prune()
    }

    func logSample(_ s: BatterySample, top: [(String, Double)]) {
        guard HistoryLog.isEnabled else { return }
        if Date().timeIntervalSince(lastPrune ?? .distantPast) > 86400 { prune() }
        if !FileManager.default.fileExists(atPath: samplesURL.path) {
            append(samplesURL, "time,percent,on_battery,charging,watts,voltage_mv,amperage_ma,temp_c,health_pct,cycles,top_processes\n")
        }
        let topStr = top.prefix(3).map { "\($0.0) \(Int($0.1))%" }.joined(separator: "; ")
            .replacingOccurrences(of: ",", with: " ")
        let row = [iso.string(from: s.date), "\(s.percent)", "\(s.onBattery)", "\(s.isCharging)",
                   String(format: "%.2f", s.watts), "\(s.voltageMV)", "\(s.amperageMA)",
                   String(format: "%.1f", s.temperatureC), String(format: "%.1f", s.healthPercent),
                   "\(s.cycleCount)", "\"\(topStr)\""].joined(separator: ",")
        append(samplesURL, row + "\n")
    }

    /// Seconds spent plugged in at or above `threshold`% since `since`, from the sample log.
    /// A gap between two such samples (e.g. asleep on the charger) counts in full, up to 12h.
    func highChargeSeconds(since: Date, threshold: Int = 90) -> Double {
        guard let text = try? String(contentsOf: samplesURL, encoding: .utf8) else { return 0 }
        var total = 0.0
        var prev: (date: Date, high: Bool)?
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", maxSplits: 3)
            guard f.count >= 3, let date = iso.date(from: String(f[0])), let pct = Int(f[1]) else { continue }
            let high = pct >= threshold && f[2] == "false"
            if let p = prev, p.high, high, date > since {
                total += min(date.timeIntervalSince(max(p.date, since)), 12 * 3600)
            }
            prev = (date, high)
        }
        return total
    }

    func logEvent(_ text: String) {
        guard HistoryLog.isEnabled else { return }
        append(eventsURL, "\(iso.string(from: Date()))  \(text)\n")
    }

    /// Drops log lines older than `retentionDays`. Both files start each line with an ISO timestamp.
    func prune() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Double(HistoryLog.retentionDays) * 86400)
        for (url, hasHeader) in [(samplesURL, true), (eventsURL, false)] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lines = text.split(separator: "\n")
            let header = hasHeader && !lines.isEmpty ? [lines.removeFirst()] : []
            let kept = lines.filter { line in
                let stamp = line.prefix { $0 != "," && $0 != " " }
                return iso.date(from: String(stamp)).map { $0 >= cutoff } ?? true
            }
            guard kept.count < lines.count else { continue }
            try? ((header + kept).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func append(_ url: URL, _ text: String) {
        let data = Data(text.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
