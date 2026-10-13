import ChargeKit
import SwiftUI

struct ChargeCapApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model = ChargeModel()
    @AppStorage("showPercentInMenuBar") private var showPercent = true

    var body: some Scene {
        Window("ChargeCap", id: "main") {
            MainWindow(model: model)
                .onAppear { AppDelegate.showInDock(true) }
                .onDisappear { AppDelegate.showInDock(false) }
        }
        .defaultSize(width: 920, height: 660)
        .commands {
            CommandGroup(after: .appInfo) { ShowWelcomeButton() }
        }

        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            Image(systemName: model.menuIcon)
            if showPercent { Text("\(model.battery.percent)%") }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon only while the window is open (the app is an LSUIElement menu bar app).
    @MainActor
    static func showInDock(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate() }
    }
}

private struct ShowWelcomeButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Welcome") {
            UserDefaults.standard.set(false, forKey: "didShowWelcome")
            openWindow(id: "main")
        }
    }
}

// MARK: - Menu bar panel: live power flow on top, settings as dropdowns below

struct MenuBarMenu: View {
    @ObservedObject var model: ChargeModel
    @AppStorage("showPercentInMenuBar") private var showPercent = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var limitOptions: [Int] {
        model.config.allowBelow80 ? [20, 30, 40, 50, 60, 70, 80, 85, 90, 95, 100] : [80, 85, 90, 95, 100]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            PowerFlowView(sample: model.power, percent: model.battery.percent, devices: model.devicePorts)
            dropdowns
            AccessoriesView(devices: model.wireless)
                .animation(.easeInOut, value: model.wireless)
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(model.battery.percent)%")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 1) {
                Text(model.stateText).font(.callout).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Open ChargeCap…") { openMainWindow() }
                Button("Settings…") { openSettings(); NSApp.activate() }
                Divider()
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Show Percentage in Menu Bar", isOn: $showPercent)
                Divider()
                Button("Quit ChargeCap") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let h = model.battery.health { parts.append("Health \(Int((h * 100).rounded()))%") }
        if let c = model.battery.cycleCount { parts.append("\(c) cycles") }
        if let t = model.battery.temperature { parts.append(String(format: "%.1f °C", t)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var dropdowns: some View {
        if model.isReady {
            HStack(spacing: 8) {
                Menu {
                    Picker("Charge Limit", selection: Binding(get: { model.config.effectiveLimit }, set: { model.setLimit($0) })) {
                        ForEach(limitOptions, id: \.self) { v in
                            Text(v >= 100 ? "Off (charge to 100%)" : "\(v)%").tag(v)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.config.effectiveLimit >= 100 ? "Limit: Off" : "Limit: \(model.config.effectiveLimit)%",
                          systemImage: "bolt.batteryblock")
                }

                Menu {
                    Toggle("Discharge When Above Limit", isOn: model.binding(\.dischargeAboveLimit))
                    Toggle("Allow Limits Below 80%", isOn: model.binding(\.allowBelow80))
                    if model.config.allowBelow80 && model.config.effectiveLimit < 80 {
                        Picker("Resume Charging At", selection: model.binding(\.sailingBand)) {
                            ForEach([2, 5, 10, 15], id: \.self) { band in
                                Text("\(model.config.effectiveLimit - band)%").tag(band)
                            }
                        }
                    }
                    Divider()
                    Button("Battery Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                    }
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }

                Button {
                    openMainWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open ChargeCap")
            }
            .controlSize(.regular)
        } else {
            Button("Install Helper to Limit Charging…") { model.install() }
                .disabled(model.busy)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        AppDelegate.showInDock(true)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: ChargeModel
    @AppStorage("showPercentInMenuBar") private var showPercent = true
    @AppStorage("didShowWelcome") private var didShowWelcome = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView {
            Form {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Show percentage in menu bar", isOn: $showPercent)
                Button("Show Welcome Again") {
                    didShowWelcome = false
                    openWindow(id: "main")
                    AppDelegate.showInDock(true)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                if model.isReady {
                    LimitControls(model: model)
                } else {
                    HelperPanel(model: model)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Charging", systemImage: "bolt.batteryblock") }

            Form { HelperPanel(model: model) }
                .formStyle(.grouped)
                .tabItem { Label("Helper", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - App icon (rendered at build time by `ChargeCap --render-icon`)

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.16, blue: 0.12), Color(red: 0.01, green: 0.03, blue: 0.04)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .fill(Color.green.opacity(0.35))
                .frame(width: 620, height: 620)
                .blur(radius: 120)
            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(AngularGradient(colors: [.mint, .green], center: .center),
                        style: StrokeStyle(lineWidth: 64, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 600, height: 600)
                .shadow(color: .green.opacity(0.8), radius: 30)
            Capsule().fill(.white.opacity(0.9)).frame(width: 16, height: 92).offset(y: -300).rotationEffect(.degrees(288))
            Image(systemName: "bolt.fill")
                .font(.system(size: 300, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.white, .mint], startPoint: .top, endPoint: .bottom))
                .shadow(color: .green, radius: 30)
        }
        .frame(width: 1024, height: 1024)
        .scaleEffect(0.82)
        .frame(width: 1024, height: 1024)
    }
}
