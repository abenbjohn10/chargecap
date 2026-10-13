import SwiftUI

/// First-launch onboarding: hero animation → features → helper setup.
/// Replay from the app menu (ChargeCap → Show Welcome).
struct WelcomeView: View {
    @ObservedObject var model: ChargeModel
    let onFinish: () -> Void

    @State private var step = 0
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let steps = 3

    var body: some View {
        ZStack {
            AuroraBackground(animated: !reduceMotion)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch step {
                    case 0: HeroStep(percent: model.battery.percent, animated: !reduceMotion)
                    case 1: FeaturesStep()
                    default: SetupStep(model: model)
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                Spacer(minLength: 0)

                HStack {
                    HStack(spacing: 6) {
                        ForEach(0..<steps, id: \.self) { i in
                            Capsule()
                                .fill(i == step ? Color.white : .white.opacity(0.3))
                                .frame(width: i == step ? 20 : 7, height: 7)
                        }
                    }
                    Spacer()
                    if step > 0 {
                        Button("Back") { go(-1) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.trailing, 12)
                    }
                    Button(action: { step == steps - 1 ? onFinish() : go(1) }) {
                        Text(step == 0 ? "Get Started" : step == steps - 1 ? (model.isReady ? "Start Using ChargeCap" : "Skip for Now") : "Continue")
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 10)
                            .background(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing),
                                        in: Capsule())
                            .foregroundStyle(.black.opacity(0.85))
                            .shadow(color: .green.opacity(0.5), radius: 12)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .animation(.spring(response: 0.35), value: step)
            }
            .padding(36)
        }
        .environment(\.colorScheme, .dark)
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { step += delta }
    }
}

// MARK: - Background

/// Slowly drifting, blurred colour blobs over near-black.
private struct AuroraBackground: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { timeline in
            let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { g in
                ZStack {
                    Color(red: 0.03, green: 0.04, blue: 0.06)
                    blob(.green, size: g.size.width * 0.7, g: g, x: 0.3 + 0.12 * sin(t * 0.21), y: 0.35 + 0.1 * cos(t * 0.17))
                    blob(.mint, size: g.size.width * 0.55, g: g, x: 0.72 + 0.1 * cos(t * 0.19), y: 0.6 + 0.12 * sin(t * 0.23))
                    blob(.teal, size: g.size.width * 0.5, g: g, x: 0.5 + 0.15 * sin(t * 0.13 + 2), y: 0.9 + 0.06 * cos(t * 0.29))
                    blob(.indigo, size: g.size.width * 0.45, g: g, x: 0.85 + 0.08 * sin(t * 0.11), y: 0.15 + 0.08 * cos(t * 0.2))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat, g: GeometryProxy, x: Double, y: Double) -> some View {
        Circle()
            .fill(color.opacity(0.35))
            .frame(width: size, height: size)
            .blur(radius: size * 0.28)
            .position(x: g.size.width * x, y: g.size.height * y)
    }
}

// MARK: - Step 1: hero

private struct HeroStep: View {
    let percent: Int
    let animated: Bool
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                EnergyParticles(animated: animated).frame(width: 300, height: 300)
                LiquidBattery(level: revealed ? Double(percent) / 100 : 0, animated: animated)
                    .frame(width: 96, height: 170)
            }
            .frame(height: 280)

            VStack(spacing: 10) {
                StaggeredTitle(text: "ChargeCap", revealed: revealed)
                Text("Charge smarter. See every watt.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 10)
                    .animation(.easeOut(duration: 0.8).delay(0.9), value: revealed)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 2.2, dampingFraction: 0.9).delay(0.2)) { revealed = true }
        }
    }
}

/// Letters rise, sharpen and fade in one after another.
private struct StaggeredTitle: View {
    let text: String
    let revealed: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, .mint], startPoint: .top, endPoint: .bottom))
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 24)
                    .blur(radius: revealed ? 0 : 8)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.35 + Double(i) * 0.06), value: revealed)
            }
        }
    }
}

/// Battery outline with a wavy liquid fill and a pulsing bolt.
private struct LiquidBattery: View {
    let level: Double
    let animated: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let body = RoundedRectangle(cornerRadius: w * 0.2)
            ZStack {
                // Terminal
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.6))
                    .frame(width: w * 0.36, height: h * 0.05)
                    .position(x: w / 2, y: h * 0.025)

                ZStack {
                    body.fill(.white.opacity(0.06))
                    TimelineView(.animation(paused: !animated)) { timeline in
                        let phase = animated ? timeline.date.timeIntervalSinceReferenceDate * 2.2 : 0
                        ZStack {
                            Wave(level: level, phase: phase + 1.4, amplitude: 5)
                                .fill(Color.mint.opacity(0.45))
                            Wave(level: level, phase: phase, amplitude: 6)
                                .fill(LinearGradient(colors: [.mint, .green], startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .clipShape(body)
                    body.strokeBorder(.white.opacity(0.75), lineWidth: 3)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: w * 0.38, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .green, radius: 10)
                        .symbolEffect(.pulse, options: .repeating, isActive: animated)
                }
                .frame(width: w, height: h * 0.94)
                .position(x: w / 2, y: h * 0.53)
                .shadow(color: .green.opacity(0.45), radius: 24)
            }
        }
    }
}

private struct Wave: Shape {
    var level: Double
    var phase: Double
    var amplitude: CGFloat

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let surface = rect.maxY - rect.height * CGFloat(min(max(level, 0), 1))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for x in stride(from: rect.minX, through: rect.maxX, by: 2) {
            let rel = Double((x - rect.minX) / rect.width)
            let y = surface + amplitude * CGFloat(sin(rel * 2 * .pi * 1.3 + phase))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Glowing particles spiralling inward into the battery.
private struct EnergyParticles: View {
    let animated: Bool
    private let count = 46

    var body: some View {
        TimelineView(.animation(paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                for i in 0..<count {
                    let seed = Double(i) * 0.6180339887
                    let progress = (t * (0.18 + 0.08 * (seed.truncatingRemainder(dividingBy: 1))) + seed)
                        .truncatingRemainder(dividingBy: 1)
                    let radius = maxR * (1 - progress) + 30 * progress
                    let angle = seed * 2 * .pi + progress * 1.6
                    let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    let alpha = sin(progress * .pi)
                    let r = 1.5 + 2.2 * (1 - progress)
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    gc.drawLayer { layer in
                        layer.addFilter(.shadow(color: .green.opacity(0.9), radius: 5))
                        layer.fill(dot, with: .color((i % 3 == 0 ? Color.mint : .green).opacity(alpha)))
                    }
                }
            }
        }
    }
}

// MARK: - Step 2: features

private struct FeaturesStep: View {
    @State private var appeared = false

    private let features: [(String, String, String, Color)] = [
        ("bolt.batteryblock.fill", "Smart charge limit", "Hold the battery at 80–100% with macOS's own limit, or go lower.", .green),
        ("point.3.filled.connected.trianglepath.dotted", "Live power flow", "Watch watts move between charger, battery, Mac and devices.", .mint),
        ("cable.connector.horizontal", "Every device", "Per-port USB-C power and Bluetooth battery levels.", .purple),
        ("heart.text.square.fill", "Battery health", "Capacity, cycle count and temperature at a glance.", .pink),
    ]

    var body: some View {
        VStack(spacing: 22) {
            Text("Everything about your power")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Array(features.enumerated()), id: \.offset) { i, f in
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: f.0)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(f.3)
                            .symbolEffect(.bounce, value: appeared)
                        Text(f.1).font(.headline).foregroundStyle(.white)
                        Text(f.2).font(.callout).foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(f.3.opacity(0.35)))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 28)
                    .scaleEffect(appeared ? 1 : 0.94)
                    .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.1 + Double(i) * 0.1), value: appeared)
                }
            }
            .frame(maxWidth: 560)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Step 3: setup

private struct SetupStep: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                if model.isReady {
                    AnimatedCheckmark().frame(width: 96, height: 96)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(LinearGradient(colors: [.mint, .green], startPoint: .top, endPoint: .bottom))
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            .frame(height: 110)
            .animation(.spring(response: 0.5), value: model.isReady)

            Text(model.isReady ? "You're all set" : "One quick setup")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(model.isReady
                 ? "ChargeCap's helper is running. Your charge limit is \(model.config.effectiveLimit >= 100 ? "off" : "\(model.config.effectiveLimit)%")."
                 : "Charge limiting needs a small background helper that runs as administrator. macOS asks for your password once.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: 420)

            if !model.isReady {
                Button {
                    model.install()
                } label: {
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.helperInstalled ? "Reinstall Helper" : "Install Helper")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                if let e = model.helperError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

/// Circle draws itself, then the tick.
private struct AnimatedCheckmark: View {
    @State private var circle = false
    @State private var tick = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: circle ? 1 : 0)
                .stroke(LinearGradient(colors: [.mint, .green], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .green.opacity(0.6), radius: 10)
            CheckShape()
                .trim(from: 0, to: tick ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .padding(26)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { circle = true }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.45)) { tick = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        return p
    }
}
