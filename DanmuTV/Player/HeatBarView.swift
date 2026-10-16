import BiliKit
import UIKit

/// 高能进度条: the danmaku heat curve drawn just above the system scrubber while the transport bar is up.
final class HeatBarView: UIView {
    private let fill = CAShapeLayer()
    private let line = CAShapeLayer()
    private var curve: HeatCurve?
    private var duration: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "player.heat"
        fill.fillColor = UIColor.white.withAlphaComponent(0.22).cgColor
        line.fillColor = nil
        line.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        line.lineWidth = 2
        line.lineJoin = .round
        layer.addSublayer(fill)
        layer.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The curve, stretched over `duration` seconds (the scrubber's full length).
    func set(_ curve: HeatCurve?, duration: Double) {
        self.curve = curve
        self.duration = duration
        accessibilityValue = curve.map { "\($0.values.count)" } ?? "0"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = bounds
        line.frame = bounds
        let points = curvePoints()
        guard points.count >= 2 else {
            fill.path = nil
            line.path = nil
            return
        }
        let top = UIBezierPath()
        top.move(to: points[0])
        // Midpoint quadratic smoothing: soft hills rather than a jagged histogram.
        for i in 1 ..< points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            top.addQuadCurve(to: mid, controlPoint: points[i - 1])
        }
        top.addLine(to: points[points.count - 1])
        line.path = top.cgPath
        let area = top.copy() as! UIBezierPath
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bounds.height))
        area.addLine(to: CGPoint(x: points[0].x, y: bounds.height))
        area.close()
        fill.path = area.cgPath
    }

    private func curvePoints() -> [CGPoint] {
        guard let curve, duration > 0, bounds.width > 0 else { return [] }
        let values = curve.normalized
        let height = bounds.height
        // A floor of 6% keeps quiet stretches visible as a baseline.
        func y(_ v: Double) -> CGFloat { height - height * (0.06 + 0.94 * v) }
        var points = values.enumerated().compactMap { i, v -> CGPoint? in
            let t = (Double(i) + 0.5) * curve.step
            guard t <= duration else { return nil }
            return CGPoint(x: bounds.width * t / duration, y: y(v))
        }
        // Reach both ends of the scrubber.
        if let first = points.first { points.insert(CGPoint(x: 0, y: first.y), at: 0) }
        if let last = points.last, last.x < bounds.width { points.append(CGPoint(x: bounds.width, y: last.y)) }
        return points
    }
}
