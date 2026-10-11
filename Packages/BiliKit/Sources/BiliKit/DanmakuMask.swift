import CoreGraphics
import Foundation

/// 弹幕防挡: Bilibili's per-video person masks (`dm_mask` in player/v2). Danmaku are drawn only inside each frame's
/// shape, so they pass behind the people on screen.
public struct DanmakuMaskInfo: Equatable, Sendable {
    public var url: URL
    public var fps: Int

    public init(url: URL, fps: Int) {
        self.url = url
        self.fps = fps
    }
}

extension API {
    public static func danmakuMask(fromPlayerInfo info: JSON) -> DanmakuMaskInfo? {
        let mask = info["dm_mask"]
        guard let url = URL(string: BiliText.imageURL(mask["mask_url"].stringValue)), url.host != nil else { return nil }
        return DanmakuMaskInfo(url: url, fps: max(1, mask["fps"].int ?? 30))
    }
}

/// A `.webmask` file: "MASK", version, check, segment count (big-endian Int32s), then a table of
/// (start ms, byte offset) Int64 pairs. Each segment (about 10 s) is gzip; inside, frames follow one another as
/// [UInt32 length][Int64 time ms][length bytes: an SVG data URI].
public struct WebMask: Sendable {
    public struct Segment: Sendable {
        /// Start time (ms).
        public var time: Int
        public var range: Range<Int>
    }

    public struct Frame: Sendable {
        /// ms.
        public var time: Int
        public var svg: String
    }

    public enum ParseError: Error {
        case notAMask, truncated, badSegment
    }

    public let segments: [Segment]
    private let data: Data

    public init(data: Data) throws {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count == 16, bytes[0 ..< 4].elementsEqual(Array("MASK".utf8)) else { throw ParseError.notAMask }
        let count = Int(Self.int32(bytes, at: 12))
        guard count > 0, count < 100_000, data.count >= 16 + count * 16 else { throw ParseError.truncated }
        let table = [UInt8](data[data.startIndex + 16 ..< data.startIndex + 16 + count * 16])
        var entries: [(time: Int, offset: Int)] = []
        for i in 0 ..< count {
            entries.append((Int(Self.int64(table, at: i * 16)), Int(Self.int64(table, at: i * 16 + 8))))
        }
        var segments: [Segment] = []
        for (i, entry) in entries.enumerated() {
            guard i == 0 || entry.time >= entries[i - 1].time else { throw ParseError.badSegment } // searches assume order
            let end = i + 1 < entries.count ? entries[i + 1].offset : data.count
            guard entry.offset >= 16 + count * 16, entry.offset < end, end <= data.count else { throw ParseError.badSegment }
            segments.append(Segment(time: entry.time, range: entry.offset ..< end))
        }
        self.segments = segments
        self.data = data
    }

    /// The segment playing at `ms`.
    public func segmentIndex(at ms: Int) -> Int? {
        guard let first = segments.first, ms >= first.time else { return segments.isEmpty ? nil : 0 }
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].time <= ms { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Decompresses and splits one segment.
    public func frames(ofSegment index: Int) throws -> [Frame] {
        let range = segments[index].range
        let compressed = data[data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound]
        guard let raw = Self.gunzip(Data(compressed)) else { throw ParseError.badSegment }
        let bytes = [UInt8](raw)
        var frames: [Frame] = []
        var p = 0
        while p + 12 <= bytes.count {
            let length = Int(Self.int32(bytes, at: p))
            let time = Int(Self.int64(bytes, at: p + 4))
            let start = p + 12
            guard length >= 0, start + length <= bytes.count else { break }
            if let text = String(bytes: bytes[start ..< start + length], encoding: .utf8) { frames.append(Frame(time: time, svg: text)) }
            p = start + length
        }
        return frames
    }

    static func int32(_ b: [UInt8], at i: Int) -> Int32 {
        Int32(bitPattern: b[i ..< i + 4].reduce(0) { $0 << 8 | UInt32($1) })
    }

    static func int64(_ b: [UInt8], at i: Int) -> Int64 {
        Int64(bitPattern: b[i ..< i + 8].reduce(0) { $0 << 8 | UInt64($1) })
    }

    /// gzip = 10-byte header (+ optional fields) + raw deflate + 8-byte trailer.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard p + 2 <= b.count else { return nil }
            p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
        }
        if flags & 0x08 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 } // FNAME
        if flags & 0x10 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 } // FCOMMENT
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p < b.count - 8 else { return nil }
        return try? (Data(b[p ..< b.count - 8]) as NSData).decompressed(using: .zlib) as Data
    }
}

/// A mask frame's shape: where danmaku may be drawn, in the mask's own coordinates (origin top-left).
/// Filled with the non-zero rule (potrace emits holes with opposite winding).
public struct MaskShape: @unchecked Sendable {
    public var size: CGSize
    public var path: CGPath

    /// The shape as an alpha-only bitmap no larger than `maxSide` pixels: cheap to use as a layer mask (scaled
    /// texture) compared with rasterizing the path at full screen size every frame.
    public func alphaImage(maxSide: CGFloat = 256) -> CGImage? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        // Path coordinates are top-left based; the bitmap context is bottom-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        context.addPath(path)
        context.setFillColor(gray: 0, alpha: 1)
        context.fillPath()
        return context.makeImage()
    }
}

/// Reads the potrace-style SVGs in mask frames: a viewBox, an optional `<g transform="translate() scale()">`
/// and `<path d>` elements (M L H V C S Q T Z, absolute and relative).
public enum SVGMask {
    public static func shape(fromFrame text: String) -> MaskShape? {
        let svg: String
        if let comma = text.range(of: "base64,") {
            // Line breaks inside the base64 are skipped by the decoder (no per-character String walk).
            guard let data = Data(base64Encoded: Data(text[comma.upperBound...].utf8), options: .ignoreUnknownCharacters),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            svg = decoded
        } else {
            svg = text
        }
        return shape(fromSVG: svg)
    }

    public static func shape(fromSVG svg: String) -> MaskShape? {
        guard let size = viewBoxSize(svg) else { return nil }
        var transform = CGAffineTransform.identity
        if let g = attribute("transform", inTag: "g", of: svg) { transform = parseTransform(g) }
        let path = CGMutablePath()
        var search = svg.startIndex ..< svg.endIndex
        while let tag = svg.range(of: "<path", range: search) {
            let rest = tag.upperBound ..< svg.endIndex
            guard let close = svg.range(of: ">", range: rest) else { break }
            let element = String(svg[tag.lowerBound ..< close.upperBound])
            if let d = attribute("d", inTag: "path", of: element) { addPath(d, to: path, transform: transform) }
            search = close.upperBound ..< svg.endIndex
        }
        return path.isEmpty ? nil : MaskShape(size: size, path: path)
    }

    static func viewBoxSize(_ svg: String) -> CGSize? {
        if let box = attribute("viewBox", inTag: "svg", of: svg) {
            let n = numbers(box)
            if n.count == 4, n[2] > 0, n[3] > 0 { return CGSize(width: n[2], height: n[3]) }
        }
        if let w = attribute("width", inTag: "svg", of: svg).flatMap({ numbers($0).first }),
           let h = attribute("height", inTag: "svg", of: svg).flatMap({ numbers($0).first }), w > 0, h > 0
        {
            return CGSize(width: w, height: h)
        }
        return nil
    }

    static func attribute(_ name: String, inTag tag: String, of text: String) -> String? {
        guard let open = text.range(of: "<\(tag)"), let end = text.range(of: ">", range: open.upperBound ..< text.endIndex) else { return nil }
        let element = text[open.upperBound ..< end.lowerBound]
        guard let key = element.range(of: " \(name)=\"") ?? element.range(of: "\n\(name)=\""),
              let quote = element.range(of: "\"", range: key.upperBound ..< element.endIndex)
        else { return nil }
        return String(element[key.upperBound ..< quote.lowerBound])
    }

    static func parseTransform(_ text: String) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            let args = numbers(String(rest[rest.index(after: open) ..< close]))
            switch name {
            case "translate": t = t.translatedBy(x: args.first ?? 0, y: args.count > 1 ? args[1] : 0)
            case "scale": t = t.scaledBy(x: args.first ?? 1, y: args.count > 1 ? args[1] : (args.first ?? 1))
            case "matrix" where args.count == 6: t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5]).concatenating(t)
            default: break
            }
            rest = rest[rest.index(after: close)...]
        }
        return t
    }

    static func numbers(_ text: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var scanner = NumberScanner(text)
        while let n = scanner.next() { out.append(n) }
        return out
    }

    /// Appends path data `d`, mapped through `transform`.
    static func addPath(_ d: String, to path: CGMutablePath, transform: CGAffineTransform) {
        var scanner = NumberScanner(d)
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuad: CGPoint?
        func map(_ p: CGPoint) -> CGPoint { p.applying(transform) }

        while let token = scanner.nextCommandOrNumber() {
            if case let .command(c) = token {
                command = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    lastQuad = nil
                }
                continue
            }
            guard case let .number(first) = token else { continue }
            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command {
            case "M", "m":
                guard let y = scanner.next() else { return }
                current = point(first, y)
                start = current
                path.move(to: map(current))
                command = relative ? "l" : "L" // further pairs are line-tos
                lastControl = nil; lastQuad = nil
            case "L", "l":
                guard let y = scanner.next() else { return }
                current = point(first, y)
                path.addLine(to: map(current))
                lastControl = nil; lastQuad = nil
            case "H", "h":
                current = CGPoint(x: relative ? current.x + first : first, y: current.y)
                path.addLine(to: map(current))
                lastControl = nil; lastQuad = nil
            case "V", "v":
                current = CGPoint(x: current.x, y: relative ? current.y + first : first)
                path.addLine(to: map(current))
                lastControl = nil; lastQuad = nil
            case "C", "c":
                guard let y1 = scanner.next(), let x2 = scanner.next(), let y2 = scanner.next(), let x = scanner.next(), let y = scanner.next() else { return }
                let c1 = point(first, y1), c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: map(end), control1: map(c1), control2: map(c2))
                current = end; lastControl = c2; lastQuad = nil
            case "S", "s":
                guard let y2 = scanner.next(), let x = scanner.next(), let y = scanner.next() else { return }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(first, y2), end = point(x, y)
                path.addCurve(to: map(end), control1: map(c1), control2: map(c2))
                current = end; lastControl = c2; lastQuad = nil
            case "Q", "q":
                guard let y1 = scanner.next(), let x = scanner.next(), let y = scanner.next() else { return }
                let c = point(first, y1), end = point(x, y)
                path.addQuadCurve(to: map(end), control: map(c))
                current = end; lastQuad = c; lastControl = nil
            case "T", "t":
                guard let y = scanner.next() else { return }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = point(first, y)
                path.addQuadCurve(to: map(end), control: map(c))
                current = end; lastQuad = c; lastControl = nil
            default:
                return // arcs and unknown commands: masks never use them
            }
        }
    }
}

/// Splits SVG number lists: "10-5.5e2,3.2.5" → 10, -550, 3.2, 0.5; also yields path commands.
struct NumberScanner {
    enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private let chars: [UInt8]
    private var i = 0

    init(_ text: String) {
        chars = Array(text.utf8)
    }

    mutating func next() -> CGFloat? {
        skipSeparators()
        return readNumber()
    }

    mutating func nextCommandOrNumber() -> Token? {
        skipSeparators()
        guard i < chars.count else { return nil }
        let c = chars[i]
        if (c >= 65 && c <= 90) || (c >= 97 && c <= 122), c != 101, c != 69 { // letters except e/E
            i += 1
            return .command(Character(UnicodeScalar(c)))
        }
        if let n = readNumber() { return .number(n) }
        i += 1 // skip anything unexpected
        return nextCommandOrNumber()
    }

    private mutating func skipSeparators() {
        while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 || chars[i] == 13 || chars[i] == 9 { i += 1 }
    }

    private mutating func readNumber() -> CGFloat? {
        let start = i
        if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
        var sawDigit = false, sawDot = false
        while i < chars.count {
            let c = chars[i]
            if c >= 48 && c <= 57 {
                sawDigit = true
            } else if c == 46, !sawDot {
                sawDot = true
            } else if (c == 101 || c == 69), sawDigit {
                // exponent
                i += 1
                if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
                while i < chars.count, chars[i] >= 48 && chars[i] <= 57 { i += 1 }
                break
            } else {
                break
            }
            i += 1
        }
        guard sawDigit, let text = String(bytes: chars[start ..< i], encoding: .ascii), let value = Double(text) else {
            i = start
            return nil
        }
        return CGFloat(value)
    }
}
