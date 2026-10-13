import ChargeKit
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case charging = "Charging"
    case devices = "Devices"
    case health = "Battery Health"
    case helper = "Helper"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .charging: return "bolt.batteryblock"
        case .devices: return "cable.connector.horizontal"
        case .health: return "heart.text.square"
        case .helper: return "lock.shield"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var model: ChargeModel
    @AppStorage("didShowWelcome") private var didShowWelcome = false
    @State private var selection: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter(model: model).padding(12)
            }
        } detail: {
            ScrollView {
                Group {
                    switch selection ?? .overview {
                    case .overview: OverviewSection(model: model)
                    case .charging: ChargingSection(model: model)
                    case .devices: DevicesSection(model: model)
                    case .health: HealthSection(model: model)
                    case .helper: Card(title: "Privileged helper") { HelperPanel(model: model) }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .id(selection)
            }
            .animation(.easeInOut(duration: 0.2), value: selection)
            .navigationTitle(selection?.rawValue ?? "ChargeCap")
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay {
            if !didShowWelcome {
                WelcomeView(model: model) {
                    withAnimation(.easeInOut(duration: 0.5)) { didShowWelcome = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
                .zIndex(1)
            }
        }
        .onAppear { model.refresh() }
    }
}

private struct SidebarFooter: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.menuIcon)
                .foregroundStyle(model.battery.isCharging ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.battery.percent)%").font(.callout.weight(.semibold).monospacedDigit())
                Text(model.stateText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sections

private struct OverviewSection: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 28) {
                BatteryGauge(percent: model.battery.percent,
                             limit: model.isReady ? model.config.effectiveLimit : 100,
                             charging: model.battery.isCharging,
                             onBattery: !model.battery.externalConnected)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.stateText).font(.title3.weight(.semibold))
                        if let t = model.timeText { Text(t).foregroundStyle(.secondary) }
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatCard(title: "Health", value: model.battery.health.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                                 symbol: "heart.fill", tint: .pink,
                                 detail: model.battery.cycleCount.map { "\($0) cycles" })
                        StatCard(title: "Temperature", value: model.battery.temperature.map { String(format: "%.1f°", $0) } ?? "—",
                                 symbol: "thermometer.medium", tint: .orange)
                        StatCard(title: "Mac draws", value: String(format: "%.1f W", model.power.systemWatts),
                                 symbol: "laptopcomputer", tint: .blue)
                        StatCard(title: model.power.batteryWatts >= 0 ? "Into battery" : "From battery",
                                 value: String(format: "%.1f W", abs(model.power.batteryWatts)),
                                 symbol: model.power.batteryWatts >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                                 tint: model.power.batteryWatts >= 0 ? .mint : .orange)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Card(title: "Power flow") {
                PowerFlowView(sample: model.power, percent: model.battery.percent, devices: model.devicePorts)
            }

            if !model.wireless.isEmpty {
                Card { AccessoriesView(devices: model.wireless) }
            }
        }
    }
}

private struct ChargingSection: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        VStack(spacing: 16) {
            if model.isReady {
                Card { LimitControls(model: model) }
            } else {
                Card(title: "Set up charge limiting") { HelperPanel(model: model) }
            }
            Card(title: "Presets") {
                HStack {
                    ForEach([80, 85, 90, 95, 100], id: \.self) { value in
                        Button(value == 100 ? "Off" : "\(value)%") { model.setLimit(value) }
                            .buttonStyle(.bordered)
                            .tint(model.config.effectiveLimit == value ? .accentColor : nil)
                            .disabled(!model.isReady)
                    }
                }
            }
            Card(title: "How it works") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("80–100%: macOS's built-in charge limit — holds during sleep and with ChargeCap closed.", systemImage: "apple.logo")
                    Label("Below 80% / discharge: the helper switches the power adapter off and on (SMC CHIE).", systemImage: "powerplug")
                    Label("The adapter is always switched back on before sleep and when the helper stops.", systemImage: "moon.zzz")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DevicesSection: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "USB-C") {
                if model.devicePorts.isEmpty {
                    Text("Nothing plugged in").foregroundStyle(.secondary)
                } else {
                    ForEach(model.devicePorts) { port in
                        HStack(spacing: 12) {
                            Image(systemName: port.kind.symbol)
                                .font(.title3).foregroundStyle(.purple)
                                .frame(width: 36, height: 36)
                                .background(.purple.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(port.title).font(.callout.weight(.medium))
                                Text("Port \(port.port) · \(port.transports.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.2f W", port.watts)).font(.callout.monospacedDigit().weight(.semibold))
                                Text(String(format: "%.2f V · %.2f A", port.volts, port.amps))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.4), value: model.devicePorts.map(\.id))

            Card {
                if model.wireless.isEmpty {
                    Text("No Bluetooth devices connected").foregroundStyle(.secondary)
                } else {
                    AccessoriesView(devices: model.wireless)
                }
            }
        }
    }
}

private struct HealthSection: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        VStack(spacing: 16) {
            if let health = model.battery.health {
                Card(title: "Maximum capacity") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "%.1f%%", health * 100))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                        CapacityBar(fraction: health)
                        Text("Compared to when it was new. Apple considers below 80% worn.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Card(title: "Details") { HealthGrid(battery: model.battery) }
        }
    }
}

private struct CapacityBar: View {
    let fraction: Double
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: fraction < 0.8 ? [.orange, .red] : [.mint, .green],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: shown ? g.size.width * fraction : 0)
                Rectangle().fill(.primary.opacity(0.5)).frame(width: 2).offset(x: g.size.width * 0.8)
            }
        }
        .frame(height: 12)
        .onAppear { withAnimation(.spring(response: 1, dampingFraction: 0.85)) { shown = true } }
    }
}
