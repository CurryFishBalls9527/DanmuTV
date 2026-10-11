import BiliKit
import CoreText
import UIKit

/// Turns danmaku into outlined text bitmaps off the main thread. Drawing text with a path stroke on the
/// main thread, right when a comment appears, used most of the frame budget during bursts and made the
/// remote feel slow; now upcoming comments are rendered ahead of time on a background queue and the frame
/// loop only picks up finished images. Identical comments (哈哈哈, 前方高能…) share one bitmap.
final class DanmakuRasterizer: @unchecked Sendable {
    struct Bitmap {
        let image: CGImage
        /// In points.
        let size: CGSize
        let scale: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let fontSize: CGFloat
        let color: UInt32
        let scale: CGFloat

        var box: NSObject { KeyBox(self) }
    }

    private final class Box: NSObject {
        let bitmap: Bitmap
        init(_ bitmap: Bitmap) { self.bitmap = bitmap }
    }

    private let cache: NSCache<NSObject, Box> = {
        let cache = NSCache<NSObject, Box>()
        cache.countLimit = 800
        return cache
    }()

    private let queue = DispatchQueue(label: "DanmuTV.danmaku-raster", qos: .userInitiated)

    /// The bitmap for `d`: from the cache when prepared, otherwise drawn now (a comment that arrived
    /// between prefetches; rare for video, the norm only if `prepare` was never called).
    func bitmap(for d: Danmaku, baseSize: CGFloat, scale: CGFloat) -> Bitmap {
        let key = Self.key(d, baseSize: baseSize, scale: scale)
        if let hit = cache.object(forKey: key.box) { return hit.bitmap }
        let bitmap = Self.render(key)
        cache.setObject(Box(bitmap), forKey: key.box)
        return bitmap
    }

    /// Renders `items` in the background; `done` (main queue) runs when they're all cached.
    func prepare(_ items: [Danmaku], baseSize: CGFloat, scale: CGFloat, done: (@MainActor @Sendable () -> Void)? = nil) {
        let keys = items.map { Self.key($0, baseSize: baseSize, scale: scale) }
        queue.async { [cache] in
            for key in keys where cache.object(forKey: key.box) == nil {
                cache.setObject(Box(Self.render(key)), forKey: key.box)
            }
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: Drawing

    private static func key(_ d: Danmaku, baseSize: CGFloat, scale: CGFloat) -> Key {
        let size = baseSize * CGFloat(min(max(d.fontSize, 12), 64)) / 25
        return Key(text: d.count > 1 ? "\(d.text) ×\(d.count)" : d.text, fontSize: size, color: d.color, scale: scale)
    }

    /// Outline = the text drawn in the outline colour at eight offsets, then the fill on top. Glyphs come
    /// from the font cache, so this costs a fraction of stroking every glyph's path.
    private static func render(_ key: Key) -> Bitmap {
        let r = Double((key.color >> 16) & 0xFF), g = Double((key.color >> 8) & 0xFF), b = Double(key.color & 0xFF)
        let fill = CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        // Dark comments get a light outline, everything else a dark one.
        let outline = 0.299 * r + 0.587 * g + 0.114 * b < 80 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let font = UIFont.systemFont(ofSize: key.fontSize, weight: .semibold)
        let fillLine = line(key.text, font: font, color: fill)
        let outlineLine = line(key.text, font: font, color: outline)

        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(fillLine, &ascent, &descent, nil))
        let pad = max(2, (key.fontSize * 0.06).rounded())
        let size = CGSize(width: ceil(width + pad * 2), height: ceil(ascent + descent + pad * 2))

        let scale = key.scale
        let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setShouldSubpixelQuantizeFonts(false)
        let origin = CGPoint(x: pad, y: pad + descent)
        let radius = pad * 0.75
        for i in 0 ..< 8 {
            let angle = Double(i) * .pi / 4
            context.textPosition = CGPoint(x: origin.x + radius * cos(angle), y: origin.y + radius * sin(angle))
            CTLineDraw(outlineLine, context)
        }
        context.textPosition = origin
        CTLineDraw(fillLine, context)
        return Bitmap(image: context.makeImage()!, size: size, scale: scale)
    }

    private static func line(_ text: String, font: UIFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}

/// NSCache needs object keys with value equality.
private final class KeyBox: NSObject {
    let key: AnyHashable
    init(_ key: AnyHashable) { self.key = key }
    override var hash: Int { key.hashValue }
    override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
}
