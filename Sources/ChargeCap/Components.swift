import ChargeKit
import SwiftUI

// MARK: - Battery gauge

/// Large ring gauge: fill sweeps to the battery level, a tick marks the charge limit,
/// and a soft glow shows while charging.
struct BatteryGauge: View {
    let percent: Int
    let limit: Int
    let charging: Bool
    let onBattery: Bool
    var size: CGFloat = 180

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return onBattery ? .orange : .green
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(charging ? 0.16 : 0.06))
                .blur(radius: 24)

            Circle().stroke(.quaternary, lineWidth: size * 0.075)

            Circle()
                .trim(from: 0, to: shown ? CGFloat(percent) / 100 : 0)
                .stroke(AngularGradient(colors: [tint.opacity(0.6), tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * Double(percent) / 100)),
                        style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.5), radius: 8)

            if limit < 100 {
                // Limit marker
                Capsule()
                    .fill(.primary.opacity(0.7))
                    .frame(width: 3, height: size * 0.11)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(360 * Double(limit) / 100))
            }

            VStack(spacing: 2) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.11, weight: .bold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }
                Text("\(percent)%")
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent)))
                if limit < 100 {
                    Text("limit \(limit)%").font(.system(size: size * 0.075)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 1.2, dampingFraction: 0.8)) { shown = true }
        }
        .animation(.easeInOut(duration: 0.8), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent\(charging ? ", charging" : "")\(limit < 100 ? ", limit \(limit) percent" : "")")
    }
}

// MARK: - Stat card

struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Card container used by the window's sections.
struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Charge limit controls

struct LimitControls: View {
    @ObservedObject var model: ChargeModel
    @State private var draftLimit: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let range: ClosedRange<Double> = model.config.allowBelow80 ? 20...100 : 80...100
            let shown = Int(draftLimit ?? Double(model.config.effectiveLimit))
            HStack(alignment: .firstTextBaseline) {
                Text("Charge limit").font(.headline)
                Spacer()
                Text(shown >= 100 ? "Off" : "\(shown)%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: shown)
            }
            Slider(
                value: Binding(get: { draftLimit ?? Double(model.config.effectiveLimit) }, set: { draftLimit = $0 }),
                in: range, step: 5
            ) { editing in
                guard !editing, let draftLimit else { return }
                self.draftLimit = nil
                model.setLimit(Int(draftLimit))
            }
            Text(model.limitExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Discharge when above limit", isOn: model.binding(\.dischargeAboveLimit))
            Toggle("Allow limits below 80%", isOn: model.binding(\.allowBelow80))
            if model.config.allowBelow80 && model.config.effectiveLimit < 80 {
                Stepper("Resume charging at \(model.config.effectiveLimit - model.config.sailingBand)%",
                        value: model.binding(\.sailingBand), in: 1...15)
                    .font(.caption)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Health grid

struct HealthGrid: View {
    let battery: BatteryInfo

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Health", battery.health.map { String(format: "%.0f%%", $0 * 100) })
            row("Capacity", battery.maxCapacity.flatMap { m in battery.designCapacity.map { "\(m) / \($0) mAh" } })
            row("Cycles", battery.cycleCount.map(String.init))
            row("Temperature", battery.temperature.map { String(format: "%.1f °C", $0) })
            row("Voltage", battery.voltage.map { String(format: "%.2f V", $0) })
            row("Battery power", battery.watts.map { String(format: "%+.1f W", $0) })
            row("Adapter", battery.adapterWatts.map { "\($0) W" } ?? (battery.externalConnected ? "Connected" : "—"))
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit()
        }
    }
}

// MARK: - Helper panel

struct HelperPanel: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(model.isReady ? Color.green : .orange).frame(width: 8, height: 8)
                Text(model.isReady ? "Helper running" : model.helperInstalled ? "Helper not responding" : "Helper not installed")
                    .font(.callout.weight(.medium))
            }
            if let s = model.status {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Version").foregroundStyle(.secondary); Text(s.version) }
                    GridRow {
                        Text("Native limit").foregroundStyle(.secondary)
                        Text(s.nativeLimitEnabled == true ? "\(s.nativeLimitValue ?? 0)%" : "Off")
                    }
                    GridRow { Text("Firmware (CHLT)").foregroundStyle(.secondary); Text(s.firmwareLimit.map { "\($0)%" } ?? "—") }
                    GridRow {
                        Text("Adapter key").foregroundStyle(.secondary)
                        Text("\(s.adapterKey ?? "none")\(s.adapterEnabled == false ? " (off)" : "")")
                    }
                    GridRow { Text("Inhibit key").foregroundStyle(.secondary); Text(s.inhibitKey ?? "none") }
                }
                .font(.caption.monospaced())
            } else {
                Text("Charge limiting needs a small privileged helper. macOS asks for your password once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = model.helperError { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(model.helperInstalled ? "Reinstall Helper" : "Install Helper") { model.install() }
                if model.helperInstalled {
                    Button("Uninstall", role: .destructive) { model.uninstall() }
                }
            }
            .disabled(model.busy)
        }
    }
}
