import ChargeKit
import SwiftUI

/// Connected Bluetooth accessories. They don't draw power from the Mac, so they get
/// battery rings instead of flow lines. Rings sweep in on appear and when levels change.
struct AccessoriesView: View {
    let devices: [WirelessDevice]

    var body: some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bluetooth devices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(devices) { AccessoryChip(device: $0) }
                }
            }
            .transition(.opacity)
        }
    }
}

private struct AccessoryChip: View {
    let device: WirelessDevice
    @State private var shown = false

    /// Earbuds report left/right/case; show the lowest bud on the ring.
    private var level: Int? {
        if let main = device.battery { return main }
        let buds = [device.left, device.right].compactMap { $0 }
        return buds.min() ?? device.caseLevel
    }

    private var tint: Color {
        guard let level else { return .secondary }
        return level <= 15 ? .red : level <= 30 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                if let level {
                    Circle()
                        .trim(from: 0, to: shown ? CGFloat(level) / 100 : 0)
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: shown)
                        .animation(.easeInOut(duration: 0.6), value: level)
                }
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(level == nil ? Color.secondary : tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.caption2).lineLimit(1)
                Text(detail).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }

    private var detail: String {
        if device.left != nil || device.right != nil {
            let parts = [("L", device.left), ("R", device.right), ("Case", device.caseLevel)]
                .compactMap { label, v in v.map { "\(label) \($0)%" } }
            return parts.joined(separator: " · ")
        }
        if let level { return "\(level)%" }
        return "Connected"
    }
}
