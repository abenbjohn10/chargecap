import ChargeKit
import SwiftUI

/// Live power-flow diagram: charger → Mac, charger → battery (inflow), battery → Mac (outflow).
/// Particles move along each path; speed, count and size scale with the wattage.
struct PowerFlowView: View {
    let sample: PowerSample
    let percent: Int
    /// Wired devices the Mac is powering (USB-C ports, excluding a USB-C charger).
    var devices: [PortPower] = []

    @State private var phases = FlowPhases()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Below this a path is drawn as idle. Accessories sip power, so their threshold is lower.
    private static let activeThreshold = 0.3
    private static let deviceThreshold = 0.03
    private static let maxDevices = 4

    private var shownDevices: [PortPower] { Array(devices.prefix(Self.maxDevices)) }
    private var height: CGFloat { max(178, 34 + CGFloat(shownDevices.count) * 62) }

    var body: some View {
        GeometryReader { geo in
            let layout = FlowLayout(size: geo.size, deviceCount: shownDevices.count)
            let edges = self.edges(layout)
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                    Canvas { gc, _ in
                        let dt = phases.advance(to: timeline.date)
                        for (i, edge) in edges.enumerated() {
                            draw(edge, index: i, dt: reduceMotion ? 0 : dt, in: &gc)
                        }
                    }
                }

                ForEach(Array(edges.prefix(3).enumerated()), id: \.offset) { i, edge in
                    // With devices attached the charger→Mac path is short; the Mac node shows its watts.
                    if edge.watts >= edge.threshold && !(i == 0 && !shownDevices.isEmpty) {
                        Text(wattsText(edge.watts))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.regularMaterial, in: Capsule())
                            .foregroundStyle(edge.color)
                            .position(edge.point(at: 0.5))
                            .transition(.opacity)
                    }
                }

                node(symbol: sample.adapterConnected ? "powerplug.fill" : "powerplug",
                     title: "Charger",
                     value: sample.adapterConnected ? wattsText(sample.adapterWatts) : "Unplugged",
                     tint: sample.adapterConnected ? .green : .secondary)
                    .position(layout.adapter)

                node(symbol: "laptopcomputer", title: "Mac", value: wattsText(sample.systemWatts), tint: .primary)
                    .position(layout.mac)

                BatteryNode(percent: percent, batteryWatts: sample.batteryWatts)
                    .position(layout.battery)

                ForEach(Array(shownDevices.enumerated()), id: \.element.id) { i, port in
                    DeviceNode(port: port, active: port.watts >= Self.deviceThreshold)
                        .position(layout.device(i))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if devices.count > Self.maxDevices {
                    Text("+\(devices.count - Self.maxDevices) more").font(.caption2).foregroundStyle(.secondary)
                        .position(x: layout.size.width - 34, y: layout.size.height - 6)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: edges.map { $0.watts >= $0.threshold })
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: shownDevices.map(\.id))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Edges

    private func edges(_ l: FlowLayout) -> [FlowEdge] {
        [
            FlowEdge(from: l.adapterPort(toward: l.mac), control: CGPoint(x: l.size.width / 2, y: l.adapter.y - 26),
                     to: l.macPort(toward: l.adapter), watts: sample.adapterToSystem, color: .green),
            FlowEdge(from: l.adapterPort(toward: l.battery), control: CGPoint(x: l.adapter.x + 8, y: l.battery.y),
                     to: l.batteryPort(toward: l.adapter), watts: sample.adapterToBattery, color: .mint),
            FlowEdge(from: l.batteryPort(toward: l.mac), control: CGPoint(x: l.mac.x - 8, y: l.battery.y),
                     to: l.macPort(toward: l.battery), watts: sample.batteryToSystem, color: .orange),
        ] + shownDevices.enumerated().map { i, port in
            let target = l.device(i)
            return FlowEdge(from: l.macPort(toward: target),
                            control: CGPoint(x: (l.mac.x + target.x) / 2, y: target.y - 14),
                            to: l.devicePort(i), watts: port.watts, color: .purple,
                            threshold: Self.deviceThreshold)
        }
    }

    private func draw(_ edge: FlowEdge, index: Int, dt: Double, in gc: inout GraphicsContext) {
        let active = edge.watts >= edge.threshold
        var track = Path()
        track.move(to: edge.from)
        track.addQuadCurve(to: edge.to, control: edge.control)

        gc.stroke(track, with: .color(active ? edge.color.opacity(0.22) : .secondary.opacity(0.12)),
                  style: StrokeStyle(lineWidth: active ? 4 : 2, lineCap: .round, dash: active ? [] : [3, 4]))
        guard active else { return }

        // log scale: a 2 W trickle and a 90 W fast charge both read clearly.
        let level = log2(1 + edge.watts / 4)
        let speed = 0.18 + 0.16 * level                 // path lengths per second
        let count = 3 + min(6, Int(edge.watts / 6))
        let radius = 2.2 + min(2.3, edge.watts / 25)
        let phase = phases.step(index, by: dt * speed)

        for i in 0..<count {
            let t = (phase + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let p = edge.point(at: t)
            // Fade in at the source, out at the destination.
            let alpha = min(1, min(t, 1 - t) * 6)
            let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            gc.drawLayer { layer in
                layer.addFilter(.shadow(color: edge.color.opacity(0.8), radius: radius * 1.6))
                layer.fill(dot, with: .color(edge.color.opacity(alpha)))
            }
        }
    }

    // MARK: Nodes

    private func node(symbol: String, title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
    }

    private func wattsText(_ w: Double) -> String { String(format: "%.1f W", w) }

    private var accessibilitySummary: String {
        let deviceText = shownDevices.map { "\($0.title) drawing \(wattsText($0.watts))" }.joined(separator: ", ")
        let suffix = deviceText.isEmpty ? "" : " Powering \(deviceText)."
        if sample.batteryToSystem >= Self.activeThreshold {
            return "On battery. Battery supplying \(wattsText(sample.batteryToSystem)) to the Mac." + suffix
        }
        var parts = ["Charger supplying \(wattsText(sample.adapterToSystem)) to the Mac"]
        if sample.adapterToBattery >= Self.activeThreshold { parts.append("and \(wattsText(sample.adapterToBattery)) into the battery") }
        return parts.joined(separator: " ") + "." + suffix
    }
}

// MARK: - Device node

private struct DeviceNode: View {
    let port: PortPower
    let active: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: port.kind.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? .purple : .secondary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.purple.opacity(active ? 0.5 : 0.15), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(port.port)")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 12, height: 12)
                        .background(.purple.opacity(0.8), in: Circle())
                        .foregroundStyle(.white)
                        .offset(x: 2, y: 2)
                        .help("USB-C port \(port.port)")
                }
            Text(shortName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 66)
            Text(active ? String(format: "%.2f W", port.watts) : "Idle")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
    }

    private var shortName: String {
        port.title
            .replacingOccurrences(of: " Magnetic Charging Cable", with: "")
            .replacingOccurrences(of: " Magnetic Fast Charger", with: "")
    }
}

// MARK: - Battery node

private struct BatteryNode: View {
    let percent: Int
    let batteryWatts: Double

    private var charging: Bool { batteryWatts >= 0.3 }
    private var discharging: Bool { batteryWatts <= -0.3 }
    private var tint: Color { discharging ? .orange : charging ? .mint : .secondary }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(tint.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 46, height: 24)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor.gradient)
                        .frame(width: max(2, (g.size.width) * CGFloat(percent) / 100))
                        .animation(.easeInOut(duration: 0.6), value: percent)
                }
                .frame(width: 40, height: 18)
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint.opacity(0.8))
                    .frame(width: 3, height: 9)
                    .offset(x: 25)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            .frame(width: 52, height: 30)
            Text("Battery \(percent)%").font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
    }

    private var fillColor: Color {
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .green
    }

    private var label: String {
        if charging { return String(format: "+%.1f W in", batteryWatts) }
        if discharging { return String(format: "−%.1f W out", -batteryWatts) }
        return "Idle"
    }
}

// MARK: - Geometry

private struct FlowLayout {
    let size: CGSize
    var deviceCount = 0

    private var hasDevices: Bool { deviceCount > 0 }
    var adapter: CGPoint { CGPoint(x: 40, y: 36) }
    /// With devices attached the Mac moves to the middle and devices stack on the right.
    var mac: CGPoint { CGPoint(x: hasDevices ? size.width * 0.5 : size.width - 40, y: 36) }
    var battery: CGPoint {
        CGPoint(x: hasDevices ? size.width * 0.27 : size.width / 2, y: size.height - 42)
    }

    func device(_ i: Int) -> CGPoint {
        let top: CGFloat = 30, bottom = size.height - 30
        let step = deviceCount > 1 ? (bottom - top) / CGFloat(deviceCount - 1) : 0
        return CGPoint(x: size.width - 34, y: deviceCount > 1 ? top + step * CGFloat(i) : 36)
    }

    func devicePort(_ i: Int) -> CGPoint {
        let d = device(i)
        return CGPoint(x: d.x - 22, y: d.y - 12)
    }

    /// Points just outside each node's icon, so paths don't run under it.
    func adapterPort(toward p: CGPoint) -> CGPoint { port(adapter, toward: p, radius: 26) }
    func macPort(toward p: CGPoint) -> CGPoint { port(mac, toward: p, radius: 26) }
    func batteryPort(toward p: CGPoint) -> CGPoint {
        CGPoint(x: battery.x + (p.x < battery.x ? -30 : 30), y: battery.y - 12)
    }

    private func port(_ c: CGPoint, toward p: CGPoint, radius: CGFloat) -> CGPoint {
        let center = CGPoint(x: c.x, y: c.y - 14)   // icon sits above the labels
        let dx = p.x - center.x, dy = p.y - center.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: center.x + dx / len * radius, y: center.y + dy / len * radius)
    }
}

private struct FlowEdge {
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let watts: Double
    let color: Color
    var threshold = 0.3

    /// Point on the quadratic Bézier at t ∈ [0, 1].
    func point(at t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }
}

/// Integrated particle phases. A reference type so per-frame updates don't trigger re-renders,
/// and integrating (instead of `time * speed`) keeps dots from jumping when the wattage changes.
private final class FlowPhases {
    private var last: Date?
    private var values: [Double] = []

    func advance(to date: Date) -> Double {
        defer { last = date }
        guard let last else { return 0 }
        return min(0.1, max(0, date.timeIntervalSince(last)))
    }

    func step(_ index: Int, by delta: Double) -> Double {
        if index >= values.count { values += [Double](repeating: 0, count: index - values.count + 1) }
        values[index] = (values[index] + delta).truncatingRemainder(dividingBy: 1)
        return values[index]
    }
}
