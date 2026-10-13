import ChargeKit
import Darwin
import Foundation

@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> UInt32

/// Runs as root. Decides, every time the battery changes, whether the Mac should
/// charge, hold, or run on battery — the same job AlDente's helper + 5 s timer do.
///
/// Backends, in the order AlDente picks them:
/// 1. macOS native Manual Charge Limit (macOS 26.4+): `mclLimitValue` / `MCLFeatureState` in
///    root's `com.apple.smartcharging.topoffprotection`, then Darwin notification
///    `com.apple.smartcharging.defaultschanged`. Firmware reflects it in SMC `CHLT`. 80...100 only.
/// 2. SMC charge inhibit on older firmware: `CHTE` (ui32, 1 = inhibit) or `CH0B`+`CH0C` (0x02 = inhibit).
/// 3. SMC adapter control: `CHIE` (0x08 = adapter off) or legacy `CH0I` (0x01). Used to discharge,
///    and to hold below 80 % when there is no inhibit key (sailing between limit-band and limit).
final class ChargeEngine: @unchecked Sendable {
    static let mclDomain = "com.apple.smartcharging.topoffprotection" as CFString
    static let mclChanged = "com.apple.smartcharging.defaultschanged"

    private let smc: SMC?
    private let queue = DispatchQueue(label: "chargecap.engine")
    private(set) var config: HelperConfig
    private var lastAction = "Starting"
    private var lastError: String?

    let adapterKey: String?
    let inhibitKey: String?

    init() {
        let smc = try? SMC()
        self.smc = smc
        config = Self.loadConfig()
        adapterKey = ["CHIE", "CH0I"].first { smc?.exists($0) == true }
        inhibitKey = ["CHTE", "CH0B"].first { smc?.exists($0) == true }
    }

    // MARK: Config

    static func loadConfig() -> HelperConfig {
        guard let data = FileManager.default.contents(atPath: ChargeCapIDs.configPath),
              let config = try? PropertyListDecoder().decode(HelperConfig.self, from: data) else { return HelperConfig() }
        return config
    }

    func apply(_ newConfig: HelperConfig) {
        queue.sync {
            config = newConfig
            let url = URL(fileURLWithPath: ChargeCapIDs.configPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? PropertyListEncoder().encode(newConfig).write(to: url)
        }
        evaluate()
    }

    // MARK: Control loop

    func evaluate() {
        queue.async { [self] in
            lastError = nil
            let battery = BatteryInfo.current()
            let limit = config.effectiveLimit

            // 1. Native limit: Apple's controller handles 80...100, including during sleep.
            let nativeTarget = limit >= 100 ? nil : max(80, Int((Double(limit) / 5).rounded(.down)) * 5)
            setNativeLimit(nativeTarget)

            // 2. Below 80: inhibit charging where firmware supports it.
            let belowNative = limit < 80
            if let inhibitKey {
                setInhibit(inhibitKey, belowNative && battery.percent >= limit)
            }

            // 3. Adapter: discharge above the limit, or sail below 80 without an inhibit key.
            guard let adapterKey else {
                lastAction = describe(battery, limit, adapterOff: false)
                return
            }
            let adapterOff = adapterIsOff(adapterKey)
            var wantOff = false
            if battery.externalConnected || adapterOff {
                if belowNative && inhibitKey == nil {
                    // Sailing: run on battery from limit down to limit - band, then charge back up.
                    let floor = limit - max(1, min(config.sailingBand, 15))
                    wantOff = adapterOff ? battery.percent > floor : battery.percent >= limit
                }
                if config.dischargeAboveLimit && battery.percent > limit {
                    wantOff = true
                }
            }
            if wantOff != adapterOff { setAdapter(adapterKey, off: wantOff) }
            lastAction = describe(battery, limit, adapterOff: wantOff)
        }
    }

    private func describe(_ b: BatteryInfo, _ limit: Int, adapterOff: Bool) -> String {
        if limit >= 100 { return "No limit — charging normally" }
        if adapterOff { return "Running on battery: \(b.percent)% → \(limit)%" }
        if !b.externalConnected { return "On battery (\(b.percent)%), limit \(limit)%" }
        if b.percent >= limit { return "Holding at \(b.percent)% (limit \(limit)%)" }
        return b.isCharging ? "Charging \(b.percent)% → \(limit)%" : "Plugged in, \(b.percent)% (limit \(limit)%)"
    }

    // MARK: Safety

    /// Leave the Mac charging normally: adapter on, no inhibit. Native limit is left as set
    /// (it is Apple's own feature and visible in System Settings → Battery).
    func restoreHardware() {
        queue.sync {
            if let adapterKey, adapterIsOff(adapterKey) { setAdapter(adapterKey, off: false) }
            if let inhibitKey { setInhibit(inhibitKey, false) }
        }
    }

    /// Never sleep with the adapter cut — the battery would drain to empty.
    func willSleep() {
        queue.sync {
            if let adapterKey, adapterIsOff(adapterKey) {
                setAdapter(adapterKey, off: false)
                lastAction = "Adapter re-enabled for sleep"
            }
        }
    }

    // MARK: Native Manual Charge Limit

    var nativeLimit: (enabled: Bool?, value: Int?) {
        let state = CFPreferencesCopyValue("MCLFeatureState" as CFString, Self.mclDomain,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
        let value = CFPreferencesCopyValue("mclLimitValue" as CFString, Self.mclDomain,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
        return (state.map { $0 != 0 }, value)
    }

    private func setNativeLimit(_ target: Int?) {
        let current = nativeLimit
        let wantEnabled = target != nil
        let wantValue = target ?? 100
        guard current.enabled != wantEnabled || current.value != wantValue else { return }
        CFPreferencesSetValue("mclLimitValue" as CFString, wantValue as CFNumber, Self.mclDomain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("MCLFeatureState" as CFString, (wantEnabled ? 1 : 0) as CFNumber, Self.mclDomain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.mclDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            lastError = "Could not save native charge limit"
            return
        }
        _ = notify_post(Self.mclChanged)
    }

    var firmwareLimit: Int? {
        (try? smc?.read("CHLT"))?.first.map(Int.init)
    }

    // MARK: SMC

    private func adapterIsOff(_ key: String) -> Bool {
        guard let byte = (try? smc?.read(key))?.first else { return false }
        return byte != 0
    }

    private func setAdapter(_ key: String, off: Bool) {
        let value: UInt8 = off ? (key == "CHIE" ? 0x08 : 0x01) : 0x00
        write(key, [value])
    }

    private func setInhibit(_ key: String, _ inhibit: Bool) {
        if key == "CHTE" {
            write("CHTE", [inhibit ? 1 : 0, 0, 0, 0])
        } else {
            write("CH0B", [inhibit ? 0x02 : 0x00])
            if smc?.exists("CH0C") == true { write("CH0C", [inhibit ? 0x02 : 0x00]) }
        }
    }

    private func write(_ key: String, _ bytes: [UInt8]) {
        do {
            if (try smc?.read(key)) == bytes { return }
            try smc?.write(key, bytes)
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Status

    func status() -> HelperStatus {
        queue.sync { () -> HelperStatus in
            let native = nativeLimit
            return HelperStatus(
                config: config,
                nativeLimitEnabled: native.enabled,
                nativeLimitValue: native.value,
                firmwareLimit: firmwareLimit,
                adapterEnabled: adapterKey.map { !adapterIsOff($0) },
                adapterKey: adapterKey,
                inhibitKey: inhibitKey,
                lastAction: lastAction,
                lastError: lastError,
                version: ChargeCapIDs.helperVersion
            )
        }
    }
}
