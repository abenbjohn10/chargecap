import AppKit
import ChargeKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class ChargeModel: ObservableObject {
    @Published var battery = BatteryInfo.current()
    @Published var status: HelperStatus?
    @Published var helperError: String?
    @Published var busy = false
    /// Local edits; pushed to the helper on change.
    @Published var config = HelperConfig()
    /// Live power flow, sampled every second and smoothed for the animation.
    @Published var power = PowerSample()
    /// USB-C ports with something plugged in that the Mac is powering.
    @Published var devicePorts: [PortPower] = []
    /// Connected Bluetooth accessories (battery levels only).
    @Published var wireless: [WirelessDevice] = []

    let client = HelperClient()
    private let sampler = PowerSampler()
    private let scanner = DeviceScanner()
    private let bluetooth = BluetoothBatteryMonitor()
    private var timer: Timer?
    private var powerTimer: Timer?

    var helperInstalled: Bool { client.isInstalled }

    init() {
        refresh()
        // Timers run in .common modes so values keep updating while a menu is open.
        timer = Self.commonTimer(5) { [weak self] in self?.refresh() }
        power = sampler.sample()
        powerTimer = Self.commonTimer(1) { [weak self] in self?.samplePower() }
        // Bluetooth batteries: system_profiler + IORegistry + GATT Battery Service (see BluetoothBatteryMonitor).
        bluetooth.$devices
            .map { $0.map(Self.wirelessDevice) }
            .removeDuplicates()
            .assign(to: &$wireless)
    }

    private static func commonTimer(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private static func wirelessDevice(_ d: BTDevice) -> WirelessDevice {
        let kind: DeviceKind = switch d.kind {
        case .speaker: .audio
        case .trackpad: .mouse
        default: DeviceKind(rawValue: d.kind.rawValue) ?? .other
        }
        return WirelessDevice(name: d.name, kind: kind,
                       battery: d.level, left: d.left, right: d.right, caseLevel: d.caseLevel)
    }

    private func samplePower() {
        let next = sampler.sample()
        // Snap on plug/unplug, smooth otherwise.
        power = next.adapterConnected != power.adapterConnected ? next : power.blended(toward: next, alpha: 0.45)
        battery.percent = BatteryInfo.current().percent
        let ports = scanner.ports().filter { $0.connected && !$0.isChargerInput }
        if ports != devicePorts { devicePorts = ports }
    }

    func refresh() {
        battery = BatteryInfo.current()
        guard client.isInstalled else {
            status = nil
            return
        }
        client.status { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let s):
                        let first = self.status == nil
                        self.status = s
                        self.helperError = s.lastError
                        if first { self.config = s.config }
                    case .failure(let e):
                        self.status = nil
                        self.helperError = "Helper unreachable: \(e.localizedDescription)"
                    }
                }
            }
        }
    }

    func push() {
        client.apply(config) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.helperError = error
                    self?.refresh()
                }
            }
        }
    }

    // MARK: Shared UI helpers (window, menu bar menu and Settings all use these)

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            helperError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var isReady: Bool { helperInstalled && status != nil }

    func setLimit(_ limit: Int) {
        config.limit = limit
        push()
    }

    /// Binding into the helper config that pushes on every change.
    func binding<T>(_ keyPath: WritableKeyPath<HelperConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.config[keyPath: keyPath] = $0; self.push() }
        )
    }

    var stateText: String {
        if let action = status?.lastAction { return action }
        if battery.isCharging { return "Charging" }
        return battery.externalConnected ? "Plugged in, not charging" : "On battery"
    }

    var timeText: String? {
        guard let t = battery.timeRemaining else { return nil }
        return "\(t / 60):\(String(format: "%02d", t % 60)) \(battery.isCharging ? "until full" : "remaining")"
    }

    var menuIcon: String {
        if status?.adapterEnabled == false { return "battery.75percent" }
        if battery.isCharging { return "battery.100percent.bolt" }
        if status != nil && battery.percent >= config.effectiveLimit { return "battery.100percent.circle" }
        return "battery.75percent"
    }

    var limitExplanation: String {
        let limit = config.effectiveLimit
        if limit >= 100 { return "Charges to 100%." }
        if limit >= 80 { return "Uses macOS's built-in charge limit, so it also holds while the Mac sleeps or ChargeCap is closed." }
        if let key = status?.inhibitKey { return "Below 80% uses the SMC charge-inhibit key (\(key))." }
        return "This Mac has no charge-inhibit key, so below 80% ChargeCap switches the adapter off at \(limit)% and back on at \(limit - config.sailingBand)%. During sleep it charges to 80%."
    }

    func install() { runScript("install-helper.sh") }
    func uninstall() { runScript("uninstall-helper.sh") }

    private func runScript(_ name: String) {
        busy = true
        client.reset()
        let error = HelperClient.runPrivileged(script: name)
        busy = false
        helperError = error
        status = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
