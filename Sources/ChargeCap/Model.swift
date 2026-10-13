import AppKit
import ChargeKit
import Combine

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
    private var wirelessTimer: Timer?
    private var timer: Timer?
    private var powerTimer: Timer?

    var helperInstalled: Bool { client.isInstalled }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        power = sampler.sample()
        powerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePower() }
        }
        scanWireless()
        wirelessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanWireless() }
        }
    }

    /// system_profiler is slow-ish, so Bluetooth is scanned off the main thread every 30 s.
    private func scanWireless() {
        DispatchQueue.global(qos: .utility).async {
            let found = DeviceScanner.wireless()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    if self?.wireless != found { self?.wireless = found }
                }
            }
        }
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
