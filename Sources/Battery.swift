import Foundation
import IOKit

/// One reading from the battery controller (AppleSmartBattery in the IORegistry).
struct BatterySample {
    let date: Date
    let percent: Int            // state of charge, 0-100
    let isCharging: Bool
    let externalConnected: Bool
    let voltageMV: Int
    let amperageMA: Int         // negative = discharging
    let temperatureC: Double
    let cycleCount: Int
    let designCapacity: Int     // mAh
    let fullChargeCapacity: Int // mAh (NominalChargeCapacity)
    let currentCapacityMAh: Int // mAh remaining
    let timeRemainingMin: Int?  // macOS estimate; nil while calculating

    /// Power flowing out of (positive) or into (negative) the battery, in watts.
    var watts: Double { -Double(voltageMV) * Double(amperageMA) / 1_000_000 }

    /// Full-charge capacity vs. design. Runs a little below Apple's figure; see `Battery.appleMaximumCapacity()`.
    var healthPercent: Double {
        designCapacity > 0 ? Double(fullChargeCapacity) / Double(designCapacity) * 100 : 0
    }

    var remainingWh: Double { Double(currentCapacityMAh) * Double(voltageMV) / 1_000_000 }

    var onBattery: Bool { !externalConnected }
}

enum Battery {
    /// The Battery Health sheet in System Settings, which holds the charge limit slider (macOS 26.4+).
    /// Apps can't set the limit themselves: powerd only accepts it from Apple-entitled processes.
    static let chargeLimitSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension?batteryhealth")!

    /// The "Maximum Capacity" shown in System Settings. macOS computes it privately (it isn't a simple
    /// ratio of the IORegistry capacities), so read it from system_profiler (~70 ms).
    static func appleMaximumCapacity() -> Int? {
        let out = shell("/usr/sbin/system_profiler", ["SPPowerDataType"])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("Maximum Capacity:") }) else { return nil }
        return Int(line.filter(\.isNumber))
    }

    static func read() -> BatterySample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int { Int((dict[key] as? NSNumber)?.int64Value ?? 0) }
        func bool(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }

        let maxCap = max(int("MaxCapacity"), 1)
        let rawMax = int("AppleRawMaxCapacity")
        let nominal = int("NominalChargeCapacity")
        let remaining = int("TimeRemaining")

        return BatterySample(
            date: Date(),
            percent: int("CurrentCapacity") * 100 / maxCap,
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected"),
            voltageMV: int("Voltage"),
            amperageMA: dict["InstantAmperage"] != nil ? int("InstantAmperage") : int("Amperage"),
            temperatureC: Double(int("Temperature")) / 100,
            cycleCount: int("CycleCount"),
            designCapacity: int("DesignCapacity"),
            fullChargeCapacity: nominal > 0 ? nominal : rawMax,
            currentCapacityMAh: int("AppleRawCurrentCapacity"),
            timeRemainingMin: (remaining > 0 && remaining < 65535) ? remaining : nil
        )
    }
}
