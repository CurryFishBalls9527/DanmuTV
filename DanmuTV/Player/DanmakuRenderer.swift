import BiliKit
import UIKit

/// Draws danmaku with CALayers. It knows nothing about where comments come from: VOD playback
/// feeds it from a timeline by media time, live rooms push comments as they arrive.
/// `now` is whatever clock the caller uses, consistently.
@MainActor
final class DanmakuRenderer: UIView {
    struct Style {
        var fontSize: CGFloat = 42
        var scrollDuration = 9.0
        var opacity: Float = 0.85
        var area = 0.5
    }

    var style = Style() {
        didSet {
            container.opacity = style.opacity
            if style.area != oldValue.area || style.fontSize != oldValue.fontSize || style.scrollDuration != oldValue.scrollDuration {
                // Lanes change meaning: drop what's on screen rather than overlap it.
                clear()
            }
        }
    }

    /// Bottom-anchored comments stay above this many points (e.g. the subtitle's height).
    var bottomInset: CGFloat = 0

    private let container = CALayer()
    /// 弹幕防挡: comments show only where this is opaque (everything outside the video, plus the frame's shape).
    private let maskRoot = CALayer()
    private let maskOutside = CAShapeLayer()
    private let maskImage = CALayer()
    private var maskKey: (time: Int, rect: CGRect, mirrored: Bool)?
    private var layout: DanmakuLayout?
    private var active: [Active] = []
    private var pool: [CALayer] = []
    private let rasterizer = DanmakuRasterizer()
    private var displayScale: CGFloat { max(1, traitCollection.displayScale) }

    private struct Active {
        var layer: CALayer
        var start: Double
        var width: Double
        var lane: Int
        var mode: Danmaku.Mode
    }

    static let fixedDuration = 4.0
    /// Upper bound on comments drawn per frame; the rest of a burst is dropped like a full screen would.
    private static let maxSpawnsPerFrame = 12

    private var laneHeight: CGFloat { style.fontSize * 1.3 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(container)
        container.opacity = style.opacity
        maskOutside.fillRule = .evenOdd
        maskRoot.addSublayer(maskOutside)
        maskRoot.addSublayer(maskImage)
        maskImage.contentsGravity = .resize
        maskImage.magnificationFilter = .linear
        for l in [maskRoot, maskOutside, maskImage] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "transform": NSNull(), "contents": NSNull()]
        }
    }

    /// Masks the comments with a frame's bitmap stretched over `videoRect` (mirrored with the video if needed), while
    /// any comments are on screen; nil (or nothing showing) removes the mask so no offscreen pass is paid for.
    /// Returns whether a mask is applied. Repeated calls for the same frame and geometry cost nothing.
    @discardableResult
    func setMask(_ frame: DanmakuMaskSource.Frame?, videoRect: CGRect, mirrored: Bool) -> Bool {
        guard let frame, !active.isEmpty, videoRect.width > 0, videoRect.height > 0 else {
            if container.mask != nil { container.mask = nil }
            maskKey = nil
            return false
        }
        if let key = maskKey, key.time == frame.time, key.rect == videoRect, key.mirrored == mirrored { return true }
        if maskKey?.rect != videoRect || maskKey?.mirrored != mirrored || container.mask == nil {
            maskRoot.frame = bounds
            let outside = CGMutablePath()
            outside.addRect(bounds)
            outside.addRect(videoRect)
            maskOutside.path = outside
            maskImage.setAffineTransform(.identity)
            maskImage.frame = videoRect
            maskImage.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            container.mask = maskRoot
        }
        maskKey = (frame.time, videoRect, mirrored)
        maskImage.contents = frame.image
        return true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        if layout?.width != Double(bounds.width) { clear() }
    }

    /// Shows comments appearing at `now`. Each is measured and placed first; only placed ones are drawn.
    func show<S: Sequence>(_ items: S, at now: Double) where S.Element == Danmaku {
        guard bounds.width > 0 else { return }
        if layout == nil { resetLayout() }
        guard var layout else { return }
        var spawned = 0
        for d in items {
            guard spawned < Self.maxSpawnsPerFrame else { break }
            let bitmap = rasterizer.bitmap(for: d, baseSize: style.fontSize, scale: displayScale)
            let size = bitmap.size
            guard let placement = layout.place(d.mode, textWidth: Double(size.width), now: now) else { continue }
            let layer = pool.popLast() ?? CALayer()
            layer.contents = bitmap.image
            layer.contentsScale = bitmap.scale
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.position = CGPoint(x: -10000, y: 0)
            layer.isHidden = false
            if layer.superlayer == nil { container.addSublayer(layer) }
            active.append(Active(layer: layer, start: now, width: Double(size.width), lane: placement.lane, mode: d.mode))
            spawned += 1
        }
        self.layout = layout
    }

    /// Renders comments that will appear soon in the background, so `show` finds them ready.
    func prepare<S: Sequence>(_ items: S) where S.Element == Danmaku {
        rasterizer.prepare(Array(items), baseSize: style.fontSize, scale: displayScale)
    }

    /// For comments pushed as they arrive (live): rendered in the background, shown once ready.
    func showWhenReady(_ d: Danmaku, now: @escaping @MainActor () -> Double) {
        rasterizer.prepare([d], baseSize: style.fontSize, scale: displayScale) { [weak self] in
            self?.show([d], at: now())
        }
    }

    /// Moves everything on screen to its position at `now`; removes what has finished.
    func step(now: Double) {
        guard let layout, !active.isEmpty else { return }
        let lane = Double(laneHeight)
        let height = Double(bounds.height - bottomInset)
        var keep: [Active] = []
        keep.reserveCapacity(active.count)
        for item in active {
            switch item.mode {
            case .scroll:
                let x = layout.x(start: item.start, textWidth: item.width, now: now)
                if x + item.width < 0 || now < item.start {
                    recycle(item.layer)
                    continue
                }
                item.layer.position = CGPoint(x: x + item.width / 2, y: lane * (Double(item.lane) + 0.5))
            case .top, .bottom:
                if now - item.start > Self.fixedDuration || now < item.start {
                    recycle(item.layer)
                    continue
                }
                let y = item.mode == .top ? lane * (Double(item.lane) + 0.5) : height - lane * (Double(item.lane) + 0.5)
                item.layer.position = CGPoint(x: Double(bounds.midX), y: y)
            }
            keep.append(item)
        }
        active = keep
    }

    func clear() {
        active.forEach { recycle($0.layer) }
        active = []
        resetLayout()
    }

    private func recycle(_ layer: CALayer) {
        layer.isHidden = true
        layer.contents = nil
        if pool.count < 200 { pool.append(layer) } else { layer.removeFromSuperlayer() }
    }

    private func resetLayout() {
        guard bounds.width > 0 else {
            layout = nil
            return
        }
        let lanes = Int(Double(bounds.height) * style.area / Double(laneHeight))
        layout = DanmakuLayout(width: Double(bounds.width), lanes: max(1, lanes), scrollDuration: style.scrollDuration,
                               fixedDuration: Self.fixedDuration)
    }
}
