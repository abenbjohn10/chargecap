import Combine
import CoreBluetooth
import Foundation
import IOKit
import os


/// Kinds use the same raw values as ChargeKit's DeviceKind so ChargeCap can map them directly.
enum BTDeviceKind: String, Sendable {
    case watch, phone, tablet, airpods, headphones, keyboard, mouse, trackpad, gamepad, speaker, other

    var symbol: String {
        switch self {
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .airpods: return "airpodspro"
        case .headphones: return "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        case .gamepad: return "gamecontroller.fill"
        case .speaker: return "hifispeaker.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    static func guess(name: String, minorType: String = "") -> BTDeviceKind {
        let n = name.lowercased(), m = minorType.lowercased()
        if n.contains("watch") { return .watch }
        if n.contains("iphone") { return .phone }
        if n.contains("ipad") { return .tablet }
        if n.contains("airpods") || n.contains("beats") { return .airpods }
        if n.contains("trackpad") { return .trackpad }
        if m.contains("keyboard") || n.contains("keyboard") { return .keyboard }
        if m.contains("mouse") || n.contains("mouse") || n.contains("mx master") { return .mouse }
        if m.contains("gamepad") || n.contains("controller") || n.contains("dualsense") { return .gamepad }
        if m.contains("headphone") || m.contains("headset") || n.contains("wh-") || n.contains("headphone") { return .headphones }
        if m.contains("speaker") || n.contains("speaker") { return .speaker }
        return .other
    }
}

struct BTDevice: Identifiable, Equatable, Sendable {
    /// Normalized name — the key all three sources are merged on.
    var id: String
    var name: String
    var kind: BTDeviceKind
    var level: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Where the battery number came from (shown in the UI, useful for debugging).
    var source: String?

    /// One number for the menu bar: main level, else the lower earbud, else the case.
    var displayLevel: Int? { level ?? [left, right].compactMap { $0 }.min() ?? caseLevel }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Battery levels of connected Bluetooth devices, merged from three sources:
///
/// 1. `system_profiler SPBluetoothDataType -json` — the list of connected devices, plus
///    `device_batteryLevelMain/Left/Right/Case` for AirPods, Beats and some classic devices.
/// 2. IORegistry `AppleDeviceManagementHIDEventService` → `BatteryPercent` — Apple Magic Keyboard,
///    Mouse and Trackpad.
/// 3. CoreBluetooth GATT Battery Service (0x180F / Battery Level 0x2A19) — Bluetooth LE devices such
///    as Logitech mice and most BLE keyboards (HID-over-GATT requires this service). We attach to the
///    link macOS already has, read the level and subscribe to notifications.
///
/// Apple Watch and iPhone batteries are not exposed to macOS apps; they show as connected only.
@MainActor
final class BluetoothBatteryMonitor: NSObject, ObservableObject {
    @Published private(set) var devices: [BTDevice] = []
    @Published private(set) var bluetoothAuthorized = true
    @Published private(set) var bluetoothOn = true

    nonisolated static let batteryService = CBUUID(string: "180F")
    nonisolated static let batteryLevel = CBUUID(string: "2A19")
    nonisolated static let hidService = CBUUID(string: "1812")

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BluetoothBatteryMonitor", category: "battery")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var gattLevels: [UUID: (name: String, level: Int)] = [:]
    private var profiler: [BTDevice] = []
    private var timers: [Timer] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        refreshProfiler()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProfiler() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachConnectedPeripherals()
                self?.rereadGatt()
            }
        })
    }

    /// Force a full rescan of all sources.
    func refresh() {
        refreshProfiler()
        attachConnectedPeripherals()
        rereadGatt()
    }

    // MARK: Merge

    private func publish() {
        var merged: [String: BTDevice] = [:]
        for d in profiler { merged[d.id] = d }

        for (name, level) in Self.registryLevels() {
            let key = BTDevice.key(name)
            var d = merged[key] ?? BTDevice(id: key, name: name, kind: .guess(name: name))
            if d.displayLevel == nil { d.level = level; d.source = "IORegistry BatteryPercent" }
            merged[key] = d
        }

        for (_, gatt) in gattLevels {
            let key = BTDevice.key(gatt.name)
            var d = merged[key] ?? BTDevice(id: key, name: gatt.name, kind: .guess(name: gatt.name))
            if d.displayLevel == nil { d.level = gatt.level; d.source = "GATT Battery Service" }
            merged[key] = d
        }

        let sorted = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != devices {
            devices = sorted
            for d in sorted {
                log.info("\(d.name, privacy: .public): \(d.displayLevel.map { "\($0)%" } ?? "no level", privacy: .public) [\(d.source ?? "-", privacy: .public)]")
            }
        }
    }

    // MARK: Source 1 — system_profiler

    private func refreshProfiler() {
        Task.detached(priority: .utility) {
            let found = Self.profilerDevices()
            await MainActor.run { [weak self] in
                self?.profiler = found
                self?.publish()
            }
        }
    }

    nonisolated static func profilerDevices() -> [BTDevice] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: [String: Any]]] else { return [] }

        func level(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            guard let s = v as? String else { return nil }
            return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        return connected.flatMap { $0 }.map { rawName, info in
            let name = rawName.trimmingCharacters(in: .whitespaces)
            var d = BTDevice(id: BTDevice.key(name), name: name,
                             kind: .guess(name: name, minorType: info["device_minorType"] as? String ?? ""))
            d.level = level(info["device_batteryLevelMain"])
            d.left = level(info["device_batteryLevelLeft"])
            d.right = level(info["device_batteryLevelRight"])
            d.caseLevel = level(info["device_batteryLevelCase"])
            if d.displayLevel != nil { d.source = "system_profiler" }
            return d
        }
    }

    // MARK: Source 2 — IORegistry (Apple Magic accessories)

    nonisolated static func registryLevels() -> [(String, Int)] {
        var out: [(String, Int)] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iterator) }
        while case let e = IOIteratorNext(iterator), e != 0 {
            defer { IOObjectRelease(e) }
            func prop(_ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if let name = prop("Product") as? String, let pct = prop("BatteryPercent") as? Int {
                out.append((name, pct))
            }
        }
        return out
    }

    // MARK: Source 3 — CoreBluetooth Battery Service

    private func attachConnectedPeripherals() {
        guard central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService, Self.hidService])
        for p in connected where peripherals[p.identifier] == nil {
            log.info("Attaching to \(p.name ?? "?", privacy: .public)")
            peripherals[p.identifier] = p
            p.delegate = self
            // macOS already holds the link; this just gives us a GATT client on it.
            central.connect(p)
        }
    }

    private func rereadGatt() {
        for p in peripherals.values where p.state == .connected {
            for s in p.services ?? [] where s.uuid == Self.batteryService {
                for c in s.characteristics ?? [] where c.uuid == Self.batteryLevel { p.readValue(for: c) }
            }
        }
    }

    private func handle(level data: Data?, from p: CBPeripheral) {
        guard let byte = data?.first, byte <= 100 else { return }
        gattLevels[p.identifier] = (p.name ?? "Bluetooth device", Int(byte))
        publish()
    }
}

extension BluetoothBatteryMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothAuthorized = CBManager.authorization != .denied && CBManager.authorization != .restricted
            bluetoothOn = central.state == .poweredOn
            if central.state == .poweredOn { attachConnectedPeripherals() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { peripherals[peripheral.identifier] = nil }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = nil
            gattLevels[peripheral.identifier] = nil
            publish()
            refreshProfiler()
        }
    }
}

extension BluetoothBatteryMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.batteryLevel {
            peripheral.readValue(for: c)
            if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel else { return }
        let value = characteristic.value
        MainActor.assumeIsolated { handle(level: value, from: peripheral) }
    }
}
