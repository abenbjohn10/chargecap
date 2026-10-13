import AppKit
import QuartzCore
import SwiftUI

/// One power path for the particle layer.
struct ParticleEdge: Equatable {
    var from: CGPoint
    var control: CGPoint
    var to: CGPoint
    var watts: Double
    var color: NSColor
    var threshold: Double

    var active: Bool { watts >= threshold }
    /// log scale: a 2 W trickle and a 90 W fast charge both read clearly.
    var speed: Double { 0.18 + 0.16 * log2(1 + watts / 4) }   // path lengths per second
    var count: Int { 3 + min(6, Int(watts / 6)) }
    var radius: CGFloat { 2.2 + min(2.3, watts / 25) }
}

/// Flowing dots as Core Animation keyframe animations along each path.
///
/// Why not SwiftUI (TimelineView/Canvas): per-frame SwiftUI updates cost ~40 % CPU with the window
/// open, and they stop while an NSMenu is tracking. CA animations run in the render server, so they
/// cost almost nothing here and keep running when a dropdown is open.
struct FlowParticles: NSViewRepresentable {
    let edges: [ParticleEdge]
    let paused: Bool

    func makeNSView(context: Context) -> ParticleHostView { ParticleHostView() }

    func updateNSView(_ view: ParticleHostView, context: Context) {
        view.update(edges: edges, paused: paused)
    }
}

final class ParticleHostView: NSView {
    /// Per edge: the container layer plus what it was built from.
    private struct Group {
        let container: CALayer
        let shape: String   // rebuild key: geometry, count, size, colour
    }

    private var groups: [Int: Group] = [:]

    override var isFlipped: Bool { true }   // match SwiftUI's top-left origin

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(edges: [ParticleEdge], paused: Bool) {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (i, edge) in edges.enumerated() {
            guard edge.active, !paused else {
                groups[i]?.container.removeFromSuperlayer()
                groups[i] = nil
                continue
            }
            let shape = Self.shapeKey(edge)
            if let group = groups[i], group.shape == shape {
                retime(group.container, to: edge.speed)
            } else {
                groups[i]?.container.removeFromSuperlayer()
                let container = build(edge)
                root.addSublayer(container)
                groups[i] = Group(container: container, shape: shape)
            }
        }
        for i in groups.keys where i >= edges.count {
            groups[i]?.container.removeFromSuperlayer()
            groups[i] = nil
        }
    }

    private static func shapeKey(_ e: ParticleEdge) -> String {
        func r(_ p: CGPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }
        return "\(r(e.from))|\(r(e.control))|\(r(e.to))|\(e.count)|\(Int(e.radius * 10))|\(e.color.description)"
    }

    /// Animations are built for 1 cycle per second; the container's `speed` sets the real rate.
    private func build(_ edge: ParticleEdge) -> CALayer {
        let container = CALayer()
        container.frame = bounds

        let path = CGMutablePath()
        path.move(to: edge.from)
        path.addQuadCurve(to: edge.to, control: edge.control)

        let r = edge.radius
        let cgColor = edge.color.cgColor

        for k in 0..<edge.count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            dot.cornerRadius = r
            dot.backgroundColor = cgColor
            dot.shadowColor = cgColor
            dot.shadowRadius = r * 1.6
            dot.shadowOpacity = 0.9
            dot.shadowOffset = .zero
            dot.opacity = 0

            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced

            // Fade in at the source, out at the destination.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.17, 0.83, 1]

            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 1
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            // Stagger dots evenly along the path by shifting each one's phase.
            group.timeOffset = Double(k) / Double(edge.count)
            dot.add(group, forKey: "flow")
            container.addSublayer(dot)
        }
        // Local time starts at 0 now; retime() relies on this beginTime/timeOffset pairing.
        container.beginTime = CACurrentMediaTime()
        container.timeOffset = 0
        container.speed = Float(edge.speed)
        return container
    }

    /// Change rate without restarting: freeze local time at its current value, then resume at the new speed.
    private func retime(_ container: CALayer, to speed: Double) {
        let newSpeed = Float(speed)
        guard abs(container.speed - newSpeed) > 0.005 else { return }
        let now = CACurrentMediaTime()
        let local = container.convertTime(now, from: nil)
        container.speed = newSpeed
        container.timeOffset = local
        container.beginTime = now
    }

    override func layout() {
        super.layout()
        for g in groups.values { g.container.frame = bounds }
    }
}
