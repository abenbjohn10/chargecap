import Foundation
import IOKit
import IOKit.ps

public struct BatteryInfo: Sendable {
    public var percent = 0
    public var isCharging = false
    public var externalConnected = false
    public var fullyCharged = false
    public var cycleCount: Int?
    public var designCapacity: Int?          // mAh
    public var maxCapacity: Int?             // mAh (AppleRawMaxCapacity)
    public var temperature: Double?          // °C
    public var voltage: Double?              // V
    public var amperage: Double?             // A, negative = discharging
    public var adapterWatts: Int?
    public var timeRemaining: Int?           // minutes

    public var health: Double? {
        guard let d = designCapacity, let m = maxCapacity, d > 0 else { return nil }
        return Double(m) / Double(d)
    }

    public var watts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    public static func current() -> BatteryInfo {
        var info = BatteryInfo()

        // Percent / charging state as the menu bar shows it.
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                info.percent = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                info.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
                info.externalConnected = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, !info.externalConnected { info.timeRemaining = t }
                if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0, info.isCharging { info.timeRemaining = t }
            }
        }

        // Health details from the AppleSmartBattery registry node.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let p = props?.takeRetainedValue() as? [String: Any] {
                // Newer macOS keeps capacities inside BatteryData; older ones at the top level.
                let data = p["BatteryData"] as? [String: Any] ?? [:]
                info.cycleCount = p["CycleCount"] as? Int
                info.designCapacity = p["DesignCapacity"] as? Int ?? data["DesignCapacity"] as? Int
                info.maxCapacity = p["NominalChargeCapacity"] as? Int ?? data["NominalChargeCapacity"] as? Int
                    ?? p["AppleRawMaxCapacity"] as? Int
                info.fullyCharged = p["FullyCharged"] as? Bool ?? false
                info.externalConnected = p["ExternalConnected"] as? Bool ?? info.externalConnected
                if let t = p["Temperature"] as? Int { info.temperature = Double(t) / 100 }
                if let v = p["Voltage"] as? Int { info.voltage = Double(v) / 1000 }
                // Negative currents arrive as two's-complement UInt64.
                if let a = p["Amperage"] as? NSNumber { info.amperage = Double(a.int64Value) / 1000 }
                if let adapter = p["AdapterDetails"] as? [String: Any] { info.adapterWatts = adapter["Watts"] as? Int }
            }
        }
        // Battery temperature from SMC TB0T (flt, little-endian) when the registry lacks it.
        if info.temperature == nil, let smc = try? SMC(), let b = try? smc.read("TB0T"), b.count == 4 {
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let t = Double(Float(bitPattern: bits))
            if t > 0 && t < 100 { info.temperature = t }
        }
        return info
    }
}
