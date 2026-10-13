import Foundation
import IOKit

public enum DeviceKind: String, Sendable {
    case watch, phone, tablet, airpods, headphones, drive, keyboard, mouse, gamepad
    case hub, audio, camera, display, thunderbolt, charger, other

    public var symbol: String {
        switch self {
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .airpods: return "airpodspro"
        case .headphones: return "headphones"
        case .drive: return "externaldrive.fill"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse.fill"
        case .gamepad: return "gamecontroller.fill"
        case .hub: return "cable.connector.horizontal"
        case .audio: return "hifispeaker.fill"
        case .camera: return "web.camera.fill"
        case .display: return "display"
        case .thunderbolt: return "bolt.horizontal.fill"
        case .charger: return "powerplug.fill"
        case .other: return "cable.connector"
        }
    }

    static func guess(name: String, interfaceClasses: Set<Int> = [], protocols: Set<Int> = [], deviceClass: Int? = nil) -> DeviceKind {
        let n = name.lowercased()
        if n.contains("watch") { return .watch }
        if n.contains("iphone") { return .phone }
        if n.contains("ipad") { return .tablet }
        if n.contains("airpods") { return .airpods }
        if interfaceClasses.contains(8) || n.contains("ssd") || n.contains("disk") || n.contains("drive") || n.contains("storage") { return .drive }
        if deviceClass == 9 || interfaceClasses.contains(9) || n.contains("hub") { return .hub }
        if interfaceClasses.contains(3) {
            if protocols.contains(1) || n.contains("keyboard") { return .keyboard }
            if protocols.contains(2) || n.contains("mouse") { return .mouse }
            if n.contains("controller") || n.contains("dualsense") { return .gamepad }
        }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("mouse") || n.contains("trackpad") { return .mouse }
        if n.contains("controller") || n.contains("gamepad") || n.contains("dualsense") { return .gamepad }
        if interfaceClasses.contains(14) || n.contains("camera") || n.contains("webcam") { return .camera }
        if interfaceClasses.contains(1) || n.contains("audio") || n.contains("speaker") { return .audio }
        if n.contains("headphone") || n.contains("headset") || n.contains("wh-") { return .headphones }
        return .other
    }
}

public struct WiredDevice: Sendable, Equatable, Identifiable {
    public var id: String { "\(port)-\(name)" }
    public var name: String
    public var kind: DeviceKind
    public var port: Int

    public init(name: String, kind: DeviceKind, port: Int) {
        self.name = name; self.kind = kind; self.port = port
    }
}

/// One USB-C / Thunderbolt port with its measured power.
public struct PortPower: Sendable, Equatable, Identifiable {
    public var id: Int { port }
    public var port: Int
    public var volts: Double
    public var amps: Double
    public var connected: Bool
    public var transports: [String]
    public var devices: [WiredDevice]

    public init(port: Int, volts: Double, amps: Double, connected: Bool, transports: [String], devices: [WiredDevice]) {
        self.port = port; self.volts = volts; self.amps = amps
        self.connected = connected; self.transports = transports; self.devices = devices
    }

    public var watts: Double { volts * amps }
    /// Macs only source 5 V on USB-C; anything higher is a charger feeding the Mac.
    public var isChargerInput: Bool { volts > 6 }

    /// Label for the port's node: one device name, or a summary.
    public var title: String {
        if isChargerInput { return "USB-C charger" }
        let leaves = devices.filter { $0.kind != .hub }
        if leaves.count == 1 { return leaves[0].name }
        if leaves.count > 1 { return "\(leaves.count) devices" }
        if transports.contains(where: { $0 == "CIO" || $0 == "PCIe" }) { return "Thunderbolt device" }
        if transports.contains("DisplayPort") { return "Display" }
        return watts > 0.05 ? "Charging device" : "USB-C device"
    }

    public var kind: DeviceKind {
        if isChargerInput { return .charger }
        let leaves = devices.filter { $0.kind != .hub }
        if leaves.count == 1 { return leaves[0].kind }
        if leaves.count > 1 { return .hub }
        if transports.contains(where: { $0 == "CIO" || $0 == "PCIe" }) { return .thunderbolt }
        if transports.contains("DisplayPort") { return .display }
        return .other
    }
}

public struct WirelessDevice: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var kind: DeviceKind
    /// Battery percentages macOS reports (main, or left/right/case for earbuds).
    public var battery: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public init(name: String, kind: DeviceKind, battery: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.name = name; self.kind = kind; self.battery = battery
        self.left = left; self.right = right; self.caseLevel = caseLevel
    }
}

/// Finds what is plugged into each USB-C port and how much power it draws.
///
/// Power: SMC `D{n}JV` (flt, volts) × `D{n}JI` (flt, amps) per port, measured by the port controller.
/// Devices: IOUSBHostDevice nodes, attributed to a port by their `usb-drd{n-1}` controller ancestor
/// (e.g. usb-drd0 → AppleT6000USBXHCI → device lives on Port-USB-C@1 / SMC D1).
public final class DeviceScanner: @unchecked Sendable {
    private let smc: SMC?

    public init() { smc = try? SMC() }

    public func ports() -> [PortPower] {
        let usb = usbDevices()
        return portNodes().map { node in
            PortPower(
                port: node.number,
                volts: float("D\(node.number)JV") ?? 0,
                amps: float("D\(node.number)JI") ?? 0,
                connected: node.connected,
                transports: node.transports,
                devices: usb.filter { $0.port == node.number }
            )
        }
    }

    // MARK: Ports

    private struct PortNode { let number: Int; let connected: Bool; let transports: [String] }

    private func portNodes() -> [PortNode] {
        // Registry names are "Port-USB-C" (ioreg shows the unit: Port-USB-C@1).
        var iterator = io_iterator_t()
        var nodes: [Int: PortNode] = [:]
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("Port-USB-C"), &iterator) == KERN_SUCCESS {
            nodes = collect(iterator)
            IOObjectRelease(iterator)
        }
        if nodes.isEmpty { nodes = scanPortsByName() }
        return nodes.values.sorted { $0.number < $1.number }
    }

    private func matching(_ cls: String) -> io_iterator_t? {
        var it = io_iterator_t()
        return IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS ? it : nil
    }

    private func collect(_ iterator: io_iterator_t) -> [Int: PortNode] {
        var out: [Int: PortNode] = [:]
        while case let e = IOIteratorNext(iterator), e != 0 {
            defer { IOObjectRelease(e) }
            if let node = portNode(e) { out[node.number] = node }
        }
        return out
    }

    private func scanPortsByName() -> [Int: PortNode] {
        var out: [Int: PortNode] = [:]
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return out }
        defer { IOObjectRelease(iterator) }
        while case let e = IOIteratorNext(iterator), e != 0 {
            defer { IOObjectRelease(e) }
            if let node = portNode(e) { out[node.number] = node }
        }
        return out
    }

    private func portNode(_ e: io_registry_entry_t) -> PortNode? {
        guard name(e).hasPrefix("Port-USB-C"), let number = property(e, "PortNumber") as? Int else { return nil }
        return PortNode(number: number,
                        connected: property(e, "ConnectionActive") as? Bool ?? false,
                        transports: property(e, "TransportsActive") as? [String] ?? [])
    }

    // MARK: USB devices

    private func usbDevices() -> [WiredDevice] {
        guard let iterator = matching("IOUSBHostDevice") else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [WiredDevice] = []
        while case let e = IOIteratorNext(iterator), e != 0 {
            defer { IOObjectRelease(e) }
            guard let port = controllerPort(e) else { continue }  // skips internal devices
            let name = (property(e, "USB Product Name") as? String)
                ?? (property(e, "kUSBProductString") as? String) ?? "USB device"
            let (classes, protocols) = interfaceClasses(e)
            let kind = DeviceKind.guess(name: name, interfaceClasses: classes, protocols: protocols,
                                        deviceClass: property(e, "bDeviceClass") as? Int)
            out.append(WiredDevice(name: name, kind: kind, port: port))
        }
        return out
    }

    /// Walk up to the `usb-drdN` controller; its index + 1 is the port number.
    private func controllerPort(_ entry: io_registry_entry_t) -> Int? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<24 {
            let n = name(current)
            if n.hasPrefix("usb-drd"), let idx = Int(n.dropFirst(7).prefix { $0.isNumber }) { return idx + 1 }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private func interfaceClasses(_ device: io_registry_entry_t) -> (Set<Int>, Set<Int>) {
        var classes = Set<Int>(), protocols = Set<Int>()
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return (classes, protocols) }
        defer { IOObjectRelease(iterator) }
        while case let e = IOIteratorNext(iterator), e != 0 {
            defer { IOObjectRelease(e) }
            if let c = property(e, "bInterfaceClass") as? Int { classes.insert(c) }
            if let p = property(e, "bInterfaceProtocol") as? Int { protocols.insert(p) }
        }
        return (classes, protocols)
    }

    // MARK: Bluetooth (battery levels only; wireless devices draw no power from the Mac)

    /// Slow (~0.1 s, spawns system_profiler) — call off the main thread, every ~30 s.
    public static func wireless() -> [WirelessDevice] {
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
            guard let s = v as? String else { return v as? Int }
            return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        return connected.flatMap { $0 }.map { name, info in
            let minor = (info["device_minorType"] as? String ?? "").lowercased()
            var kind = DeviceKind.guess(name: name)
            if kind == .other {
                kind = minor.contains("headphone") || minor.contains("headset") ? .headphones
                    : minor.contains("keyboard") ? .keyboard
                    : minor.contains("mouse") ? .mouse
                    : minor.contains("gamepad") ? .gamepad : .other
            }
            return WirelessDevice(name: name.trimmingCharacters(in: .whitespaces), kind: kind,
                                  battery: level(info["device_batteryLevelMain"]),
                                  left: level(info["device_batteryLevelLeft"]),
                                  right: level(info["device_batteryLevelRight"]),
                                  caseLevel: level(info["device_batteryLevelCase"]))
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: Helpers

    private func float(_ key: String) -> Double? {
        guard let b = try? smc?.read(key), b.count == 4 else { return nil }
        let v = Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        return v.isFinite ? max(0, v) : nil
    }

    private func name(_ e: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(e, &buf)
        return String(cString: buf)
    }

    private func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
