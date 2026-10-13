import ChargeKit
import SwiftUI

struct ChargeCapApp: App {
    @StateObject private var model = ChargeModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: menuIcon)
            Text("\(model.battery.percent)%")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if model.status?.adapterEnabled == false { return "battery.75percent" }
        if model.battery.isCharging { return "battery.100percent.bolt" }
        if model.status != nil && model.battery.percent >= model.config.effectiveLimit { return "battery.100percent.circle" }
        return "battery.75percent"
    }
}

struct MenuContent: View {
    @ObservedObject var model: ChargeModel
    @State private var draftLimit: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PowerFlowView(sample: model.power, percent: model.battery.percent, devices: model.devicePorts)
            AccessoriesView(devices: model.wireless)
                .animation(.easeInOut, value: model.wireless)
            Divider()
            if model.helperInstalled && model.status != nil {
                limitControls
                Divider()
            } else {
                installPrompt
                Divider()
            }
            health
            Divider()
            helperInfo
            HStack {
                Button("Battery Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(model.battery.percent)%").font(.system(size: 34, weight: .semibold)).monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status?.lastAction ?? powerSourceText).font(.callout)
                if let t = model.battery.timeRemaining {
                    Text("\(t / 60):\(String(format: "%02d", t % 60)) \(model.battery.isCharging ? "until full" : "remaining")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var powerSourceText: String {
        if model.battery.isCharging { return "Charging" }
        return model.battery.externalConnected ? "Plugged in, not charging" : "On battery"
    }

    private var limitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let range: ClosedRange<Double> = model.config.allowBelow80 ? 20...100 : 80...100
            let shown = Int(draftLimit ?? Double(model.config.effectiveLimit))
            HStack {
                Text("Charge limit").font(.headline)
                Spacer()
                Text(shown >= 100 ? "Off" : "\(shown)%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { draftLimit ?? Double(model.config.effectiveLimit) }, set: { draftLimit = $0 }),
                in: range, step: 5
            ) { editing in
                guard !editing, let draftLimit else { return }
                model.config.limit = Int(draftLimit)
                self.draftLimit = nil
                model.push()
            }
            Text(limitExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Discharge when above limit", isOn: binding(\.dischargeAboveLimit))
            Toggle("Allow limits below 80%", isOn: binding(\.allowBelow80))
            if model.config.allowBelow80 && model.config.effectiveLimit < 80 {
                Stepper("Resume charging at \(model.config.effectiveLimit - model.config.sailingBand)%",
                        value: binding(\.sailingBand), in: 1...15)
                    .font(.caption)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var limitExplanation: String {
        let limit = model.config.effectiveLimit
        if limit >= 100 { return "Charges to 100%." }
        if limit >= 80 { return "Uses macOS's built-in charge limit, so it also holds while the Mac sleeps or ChargeCap is closed." }
        if model.status?.inhibitKey != nil { return "Below 80% uses the SMC charge-inhibit key (\(model.status!.inhibitKey!))." }
        return "This Mac has no charge-inhibit key, so below 80% ChargeCap switches the adapter off at \(limit)% and back on at \(limit - model.config.sailingBand)%. During sleep it charges to 80%."
    }

    private var installPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Charge limiting needs a small privileged helper (asks for your password once).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(model.helperInstalled ? "Reinstall helper" : "Install helper") { model.install() }
                .disabled(model.busy)
        }
    }

    private var health: some View {
        let b = model.battery
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Health", b.health.map { String(format: "%.0f%%", $0 * 100) })
            row("Capacity", b.maxCapacity.flatMap { m in b.designCapacity.map { "\(m) / \($0) mAh" } })
            row("Cycles", b.cycleCount.map(String.init))
            row("Temperature", b.temperature.map { String(format: "%.1f °C", $0) })
            row("Power", b.watts.map { String(format: "%+.1f W", $0) })
            row("Adapter", b.adapterWatts.map { "\($0) W" } ?? (b.externalConnected ? "Connected" : "—"))
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit()
        }
    }

    private var helperInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = model.status {
                Text("Helper v\(s.version) · native limit \(s.nativeLimitEnabled == true ? "\(s.nativeLimitValue ?? 0)%" : "off") · firmware CHLT \(s.firmwareLimit.map { "\($0)%" } ?? "—")")
                Text("Adapter key \(s.adapterKey ?? "none")\(s.adapterEnabled == false ? " (off)" : "") · inhibit key \(s.inhibitKey ?? "none")")
            }
            if let e = model.helperError { Text(e).foregroundStyle(.red) }
            if model.helperInstalled {
                Button("Uninstall helper") { model.uninstall() }.disabled(model.busy).controlSize(.small)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<HelperConfig, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: { model.config[keyPath: keyPath] = $0; model.push() }
        )
    }
}
