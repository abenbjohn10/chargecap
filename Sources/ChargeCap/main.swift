import AppKit
import ChargeKit
import Foundation
import SwiftUI

/// CLI for testing (must run from inside the signed ChargeCap.app so the helper accepts it):
///   ChargeCap --status
///   ChargeCap --set-limit 85 [--below80] [--discharge]
///   ChargeCap --smc            (read-only dump of charge-related SMC keys, no helper needed)
func waitFor(_ body: (@escaping () -> Void) -> Void) {
    let sem = DispatchSemaphore(value: 0)
    body { sem.signal() }
    _ = sem.wait(timeout: .now() + 10)
}

func printBattery() {
    let b = BatteryInfo.current()
    print("Battery: \(b.percent)% charging=\(b.isCharging) external=\(b.externalConnected) cycles=\(b.cycleCount ?? -1)"
        + " health=\(b.health.map { String(format: "%.1f%%", $0 * 100) } ?? "?")"
        + " temp=\(b.temperature.map { String(format: "%.1f°C", $0) } ?? "?")"
        + " power=\(b.watts.map { String(format: "%+.1fW", $0) } ?? "?")")
}

func printStatus(_ client: HelperClient) {
    waitFor { done in
        client.status { result in
            switch result {
            case .success(let s):
                let json = (try? JSONEncoder.pretty.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
                print("Helper:", json)
            case .failure(let e):
                print("Helper error:", e.localizedDescription)
            }
            done()
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    // Build step: render AppIconView into an .iconset for iconutil.
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    MainActor.assumeIsolated {
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let px = CGFloat(points * scale)
            let renderer = ImageRenderer(content: AppIconView().scaleEffect(px / 1024).frame(width: px, height: px))
            renderer.scale = 1
            guard let cg = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try? png.write(to: dir.appendingPathComponent(name))
        }
    }
} else if let i = args.firstIndex(of: "--snapshot-panel"), i + 1 < args.count {
    // Dev aid: render the menu bar panel with live data.
    MainActor.assumeIsolated {
        let model = ChargeModel()
        RunLoop.main.run(until: Date().addingTimeInterval(9))   // helper status + Bluetooth GATT reads
        let renderer = ImageRenderer(content: MenuBarMenu(model: model).background(Color(white: 0.16))
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            print("wrote panel")
        }
    }
} else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    // Dev aid: render the power-flow view for each state to PNGs.
    let dir = URL(fileURLWithPath: args[i + 1])
    let states: [(String, PowerSample, Int)] = [
        ("charging", PowerSample(adapterWatts: 56.5, systemWatts: 9.4, batteryWatts: 46.7, adapterConnected: true), 81),
        ("holding", PowerSample(adapterWatts: 7.5, systemWatts: 7.6, batteryWatts: 0, adapterConnected: true), 80),
        ("battery", PowerSample(adapterWatts: 0, systemWatts: 10.3, batteryWatts: -10.6, adapterConnected: false), 79),
    ]
    // Sample devices for the render (the live app uses DeviceScanner).
    let watch = PortPower(port: 1, volts: 5.23, amps: 0.10, connected: true, transports: ["CC", "USB2"],
                          devices: [WiredDevice(name: "Apple Watch Magnetic Charging Cable", kind: .watch, port: 1)])
    let drive = PortPower(port: 2, volts: 5.1, amps: 0.42, connected: true, transports: ["CC", "USB3"],
                          devices: [WiredDevice(name: "Samsung T7", kind: .drive, port: 2)])
    let phone = PortPower(port: 3, volts: 5.0, amps: 1.9, connected: true, transports: ["CC", "USB2"],
                          devices: [WiredDevice(name: "iPhone", kind: .phone, port: 3)])
    let accessories = [
        WirelessDevice(name: "AirPods Pro", kind: .airpods, battery: nil, left: 82, right: 79, caseLevel: 55),
        WirelessDevice(name: "MX Master 3S", kind: .mouse, battery: 64),
        WirelessDevice(name: "Kreo Swarm 5.0", kind: .keyboard, battery: nil),
        WirelessDevice(name: "DualSense", kind: .gamepad, battery: 12),
    ]
    MainActor.assumeIsolated {
        for (name, sample, percent) in states {
            let devices: [PortPower] = name == "holding" ? [watch] : name == "charging" ? [watch, drive, phone] : [watch, drive]
            let view = VStack(spacing: 12) {
                PowerFlowView(sample: sample, percent: percent, devices: devices)
                AccessoriesView(devices: name == "charging" ? accessories : [])
            }
                .frame(width: 292).padding(14).background(Color(white: 0.16)).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("flow-\(name).png"))
                print("wrote flow-\(name).png")
            }
        }
    }
} else if args.contains("--devices") {
    for port in DeviceScanner().ports() {
        print(String(format: "Port %d: %.2f V × %.3f A = %.2f W  connected=%@ transports=%@  → %@ [%@]",
                     port.port, port.volts, port.amps, port.watts, port.connected ? "yes" : "no",
                     port.transports.joined(separator: ","), port.title, port.kind.rawValue))
        for d in port.devices { print("    • \(d.name) [\(d.kind.rawValue)]") }
    }
    print("Bluetooth (connected):")
    MainActor.assumeIsolated {
        let monitor = BluetoothBatteryMonitor()
        RunLoop.main.run(until: Date().addingTimeInterval(8))   // let GATT reads arrive
        for d in monitor.devices {
            print("    • \(d.name) [\(d.kind.rawValue)] battery=\(d.displayLevel.map { "\($0)%" } ?? "-")"
                  + " L=\(d.left.map(String.init) ?? "-") R=\(d.right.map(String.init) ?? "-") case=\(d.caseLevel.map(String.init) ?? "-")"
                  + "  via \(d.source ?? "-")")
        }
    }
} else if args.contains("--power") {
    let sampler = PowerSampler()
    for _ in 0..<5 {
        let s = sampler.sample()
        print(String(format: "adapter %5.1f W | system %5.1f W | battery %+6.1f W | charger→Mac %5.1f  charger→battery %5.1f  battery→Mac %5.1f",
                     s.adapterWatts, s.systemWatts, s.batteryWatts, s.adapterToSystem, s.adapterToBattery, s.batteryToSystem))
        Thread.sleep(forTimeInterval: 1)
    }
} else if args.contains("--smc") {
    let smc = try SMC()
    for key in ["CHLT", "CHIE", "CH0I", "CHTE", "CH0B", "CH0C", "BRSC", "TB0T"] {
        if let info = try? smc.info(key), let bytes = try? smc.read(key) {
            print(key, info.type, bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        } else {
            print(key, "not present")
        }
    }
} else if args.contains("--status") {
    printBattery()
    printStatus(HelperClient())
} else if let i = args.firstIndex(of: "--set-limit"), i + 1 < args.count, let limit = Int(args[i + 1]) {
    let client = HelperClient()
    var config = HelperConfig()
    waitFor { done in
        client.status { if case .success(let s) = $0 { config = s.config }; done() }
    }
    config.limit = limit
    config.allowBelow80 = args.contains("--below80")
    config.dischargeAboveLimit = args.contains("--discharge")
    waitFor { done in
        client.apply(config) { err in print(err.map { "Error: \($0)" } ?? "Applied limit \(config.effectiveLimit)%"); done() }
    }
    Thread.sleep(forTimeInterval: 2)
    printBattery()
    printStatus(client)
} else {
    ChargeCapApp.main()
}
