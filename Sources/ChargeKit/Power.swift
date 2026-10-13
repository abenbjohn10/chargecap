import Foundation

/// Instantaneous power flow. Read straight from the SMC (no root needed), ~every second.
public struct PowerSample: Sendable, Equatable {
    /// Power coming in from the charger (W). 0 on battery.
    public var adapterWatts: Double
    /// Whole-system consumption (W).
    public var systemWatts: Double
    /// Battery power: positive = charging (inflow), negative = discharging (outflow).
    public var batteryWatts: Double
    public var adapterConnected: Bool

    public init(adapterWatts: Double = 0, systemWatts: Double = 0, batteryWatts: Double = 0, adapterConnected: Bool = false) {
        self.adapterWatts = adapterWatts
        self.systemWatts = systemWatts
        self.batteryWatts = batteryWatts
        self.adapterConnected = adapterConnected
    }

    /// Adapter power going to the Mac itself (not into the battery).
    public var adapterToSystem: Double { positive(min(adapterWatts, systemWatts)) }
    public var adapterToBattery: Double { positive(batteryWatts) }
    public var batteryToSystem: Double { positive(-batteryWatts) }

    private func positive(_ v: Double) -> Double { v > 0 ? v : 0 }  // never "-0.0"

    /// Exponential smoothing so the animation doesn't jitter between samples.
    public func blended(toward next: PowerSample, alpha: Double) -> PowerSample {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * alpha }
        return PowerSample(adapterWatts: mix(adapterWatts, next.adapterWatts),
                           systemWatts: mix(systemWatts, next.systemWatts),
                           batteryWatts: mix(batteryWatts, next.batteryWatts),
                           adapterConnected: next.adapterConnected)
    }
}

/// SMC keys (Apple Silicon, little-endian):
///   PDTR flt  DC-in (adapter) power, W
///   PSTR flt  system total power, W
///   B0AV ui16 battery voltage, mV
///   B0AC si16 battery current, mA (+ charging, − discharging)
/// Falls back to the AppleSmartBattery registry when a key is missing.
public final class PowerSampler: @unchecked Sendable {
    private let smc: SMC?

    public init() { smc = try? SMC() }

    public func sample() -> PowerSample {
        let battery = BatteryInfo.current()
        var s = PowerSample(adapterConnected: battery.externalConnected)

        if let mv = uint16("B0AV"), let ma = int16("B0AC") {
            s.batteryWatts = Double(mv) / 1000 * Double(ma) / 1000
        } else {
            s.batteryWatts = battery.watts ?? 0
        }

        let adapter = float("PDTR")
        let system = float("PSTR")
        s.adapterWatts = s.adapterConnected ? max(0, adapter ?? 0) : 0
        s.systemWatts = system ?? (s.adapterWatts - s.batteryWatts)
        if adapter == nil && s.adapterConnected { s.adapterWatts = s.systemWatts + max(0, s.batteryWatts) }
        if !s.adapterConnected && system == nil { s.systemWatts = max(0, -s.batteryWatts) }
        return s
    }

    private func bytes(_ key: String, _ count: Int) -> [UInt8]? {
        guard let b = try? smc?.read(key), b.count == count else { return nil }
        return b
    }

    private func float(_ key: String) -> Double? {
        guard let b = bytes(key, 4) else { return nil }
        let v = Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        return v.isFinite ? v : nil
    }

    private func uint16(_ key: String) -> UInt16? {
        bytes(key, 2).map { UInt16($0[0]) | UInt16($0[1]) << 8 }
    }

    private func int16(_ key: String) -> Int16? {
        uint16(key).map { Int16(bitPattern: $0) }
    }
}
