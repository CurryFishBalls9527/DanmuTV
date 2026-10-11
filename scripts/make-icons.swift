// Renders the Danmu TV icon (all themes), the Settings previews and the Top Shelf images.
//   swift scripts/make-icons.swift DanmuTV/Resources/Assets.xcassets <dir for Top Shelf PNGs>
// then convert the Top Shelf PNGs to JPEG into the brand assets (sips -s format jpeg …).
import AppKit
import CoreGraphics

typealias Draw = (CGContext, CGFloat, CGFloat) -> Void
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
struct Theme { let name: String; let top: UInt32; let bottom: UInt32; let glow: CGFloat; let bubble: UInt32; let play: UInt32; let stream: UInt32 }
let themes = [
    Theme(name: "Classic", top: 0xFF6B4A, bottom: 0xFFB23F, glow: 0.18, bubble: 0xFFFFFF, play: 0xFF7A45, stream: 0xFFFFFF),
    Theme(name: "Midnight", top: 0x1A1F3A, bottom: 0x070912, glow: 0.10, bubble: 0xFF7A45, play: 0xFFFFFF, stream: 0xFF9A5C),
    Theme(name: "Light", top: 0xFFFFFF, bottom: 0xF1F2F6, glow: 0.0, bubble: 0xFF7A45, play: 0xFFFFFF, stream: 0xFF9A5C),
]

func render(_ w: Int, _ h: Int, _ draws: [Draw]) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for d in draws { d(ctx, CGFloat(w), CGFloat(h)) }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func background(_ t: Theme) -> Draw {
    { ctx, w, h in
        let g = CGGradient(colorsSpace: nil, colors: [rgb(t.top), rgb(t.bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        if t.glow > 0 {
            let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, t.glow), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: w * 0.42, y: h * 0.62), startRadius: 0,
                                   endCenter: CGPoint(x: w * 0.42, y: h * 0.62), endRadius: min(w, h) * 0.8, options: [])
        }
    }
}

func pill(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
    ctx.fillPath()
}

/// The glyph in a box of height `h`, horizontally centred on `cx` (defaults to the middle).
func glyph(_ t: Theme, scale: CGFloat = 1, centerX: CGFloat? = nil) -> Draw {
    { ctx, w, h in
        let bh = h * 0.5 * scale, bw = bh * 1.25
        let total = bw + bh * 0.12 + bw * 0.5
        let x = (centerX ?? w / 2) - total / 2, y = (h - bh) / 2 + bh * 0.06
        let bubble = CGMutablePath()
        bubble.addRoundedRect(in: CGRect(x: x, y: y, width: bw, height: bh), cornerWidth: bh * 0.3, cornerHeight: bh * 0.3)
        bubble.move(to: CGPoint(x: x + bw * 0.22, y: y + 2)); bubble.addLine(to: CGPoint(x: x + bw * 0.12, y: y - bh * 0.2))
        bubble.addLine(to: CGPoint(x: x + bw * 0.42, y: y + 2)); bubble.closeSubpath()
        ctx.setFillColor(rgb(t.bubble)); ctx.addPath(bubble); ctx.fillPath()
        let s = bh * 0.42, cx = x + bw / 2 + s * 0.06, cy = y + bh / 2
        ctx.setFillColor(rgb(t.play))
        ctx.move(to: CGPoint(x: cx - s * 0.42, y: cy + s * 0.5)); ctx.addLine(to: CGPoint(x: cx + s * 0.5, y: cy))
        ctx.addLine(to: CGPoint(x: cx - s * 0.42, y: cy - s * 0.5)); ctx.closePath(); ctx.fillPath()
        let ph = bh * 0.11
        pill(ctx, CGRect(x: x + bw + bh * 0.12, y: y + bh * 0.68, width: bw * 0.5, height: ph), rgb(t.stream, 0.92))
        pill(ctx, CGRect(x: x + bw + bh * 0.22, y: y + bh * 0.44, width: bw * 0.34, height: ph), rgb(t.stream, 0.62))
        pill(ctx, CGRect(x: x + bw + bh * 0.12, y: y + bh * 0.20, width: bw * 0.44, height: ph), rgb(t.stream, 0.8))
    }
}

func wordmark(_ t: Theme) -> Draw {
    { ctx, w, h in
        background(t)(ctx, w, h)
        glyph(t, scale: 0.85, centerX: w * 0.33)(ctx, w, h)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let text = NSAttributedString(string: "Danmu TV", attributes: [.font: NSFont.systemFont(ofSize: h * 0.2, weight: .heavy),
                                                                      .foregroundColor: NSColor.white])
        text.draw(at: CGPoint(x: w * 0.33 + h * 0.5, y: (h - text.size().height) / 2 - h * 0.02))
        NSGraphicsContext.restoreGraphicsState()
    }
}

let A = CommandLine.arguments[1] // Assets.xcassets
func write(_ data: Data, _ path: String) { try! data.write(to: URL(fileURLWithPath: A + "/" + path)) }
let brand = "App Icon & Top Shelf Image.brandassets"
let classic = themes[0]
write(render(400, 240, [background(classic)]), "\(brand)/App Icon.imagestack/Back.imagestacklayer/Content.imageset/Classic-back-small.png")
write(render(800, 480, [background(classic)]), "\(brand)/App Icon.imagestack/Back.imagestacklayer/Content.imageset/Classic-back-small@2x.png")
write(render(400, 240, [glyph(classic)]), "\(brand)/App Icon.imagestack/Front.imagestacklayer/Content.imageset/Classic-front-small.png")
write(render(800, 480, [glyph(classic)]), "\(brand)/App Icon.imagestack/Front.imagestacklayer/Content.imageset/Classic-front-small@2x.png")
write(render(1280, 768, [background(classic)]), "\(brand)/App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/Classic-back-store.png")
write(render(1280, 768, [glyph(classic)]), "\(brand)/App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/Classic-front-store.png")
for t in themes {
    if t.name != "Classic" {
        for (suffix, w, h) in [("small", 400, 240), ("small@2x", 800, 480)] {
            write(render(w, h, [background(t)]), "\(t.name).imagestack/Back.imagestacklayer/Content.imageset/\(t.name)-back-\(suffix).png")
            write(render(w, h, [glyph(t)]), "\(t.name).imagestack/Front.imagestacklayer/Content.imageset/\(t.name)-front-\(suffix).png")
        }
    }
    write(render(800, 480, [background(t)]), "IconPreview-\(t.name)-back.imageset/image.png")
    write(render(800, 480, [glyph(t)]), "IconPreview-\(t.name)-front.imageset/image.png")
}
for (name, w, h) in [("shelf", 1920, 720), ("shelf@2x", 3840, 1440), ("wide", 2320, 720), ("wide@2x", 4640, 1440)] {
    try! render(w, h, [wordmark(classic)]).write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "/TopShelf-\(name).png"))
}
print("ok")
