import Foundation

@discardableResult
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Cumulative CPU seconds per PID, from `ps`. Works for processes owned by any user (including root daemons).
enum ProcessSampler {
    struct Entry {
        let pid: Int
        let cpuSeconds: Double
        let name: String      // grouped name: the owning app (e.g. "Google Chrome") or the executable
        let appPath: String?  // owning .app bundle, used for its icon
    }

    static func snapshot() -> [Int: Entry] {
        var result: [Int: Entry] = [:]
        for line in shell("/bin/ps", ["-axo", "pid=,time=,comm="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]) else { continue }
            let path = String(parts[2])
            let app = owningApp(path)
            result[pid] = Entry(pid: pid, cpuSeconds: parseTime(String(parts[1])),
                                name: app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                                    ?? (path as NSString).lastPathComponent,
                                appPath: app)
        }
        return result
    }

    /// Accepts "MM:SS.ss", "HH:MM:SS", or "D-HH:MM:SS".
    static func parseTime(_ s: String) -> Double {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var total = 0.0
        for (i, comp) in rest.split(separator: ":").reversed().enumerated() {
            total += (Double(comp) ?? 0) * pow(60, Double(i))
        }
        return total + days * 86400
    }

    /// The outermost .app containing `path`, so helper processes count toward their app
    /// (".../Google Chrome.app/.../Google Chrome Helper (Renderer)" -> ".../Google Chrome.app").
    /// System daemons and apps under /System/Library are left ungrouped.
    static func owningApp(_ path: String) -> String? {
        guard !path.hasPrefix("/System/Library"), let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

/// Things currently keeping the Mac awake (pmset -g assertions).
enum SleepBlockers {
    static func current() -> [String] {
        let out = shell("/usr/bin/pmset", ["-g", "assertions"])
        let regex = try! NSRegularExpression(pattern: #"pid \d+\((.+?)\): \[.*?\] ([\d:]+) (\w+) named: "(.*?)""#)
        let interesting: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep",
                                        "PreventUserIdleDisplaySleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]
        var result: [String] = []
        for line in out.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let proc = ns.substring(with: m.range(at: 1))
            let type = ns.substring(with: m.range(at: 3))
            let reason = ns.substring(with: m.range(at: 4))
            guard interesting.contains(type) else { continue }
            if proc == "powerd" && reason.contains("display is on") { continue } // normal while screen is on
            result.append(reason.localizedCaseInsensitiveContains(proc) ? reason : "\(proc) · \(reason)")
        }
        return result
    }
}

func systemUptimeDays() -> Double {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return max(0, Date().timeIntervalSince1970 - Double(tv.tv_sec)) / 86400
}

func notify(_ title: String, _ body: String) {
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    shell("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
}

func formatDuration(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : (m < 1 ? "<1m" : "\(m)m")
}
