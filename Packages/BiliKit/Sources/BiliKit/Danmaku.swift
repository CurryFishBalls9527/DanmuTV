import Foundation

/// One bullet comment.
public struct Danmaku: Hashable, Sendable {
    public enum Mode: Sendable {
        case scroll, top, bottom
    }

    public var id: Int64
    /// Seconds into the video (clamped to ≥ 0; Bilibili has some negative timestamps).
    public var time: Double
    public var mode: Mode
    /// Bilibili size class: 18 small, 25 normal, 36 large.
    public var fontSize: Int
    /// 0xRRGGBB.
    public var color: UInt32
    public var text: String
    /// Smart-filter score 0–11; low = likely spam.
    public var weight: Int
    /// Sender hash, for user blocks.
    public var senderHash: String
    /// How many identical comments were merged into this one (弹幕聚合).
    public var count: Int = 1

    public init(id: Int64, time: Double, mode: Mode, fontSize: Int = 25, color: UInt32 = 0xFFFFFF, text: String,
                weight: Int = 10, senderHash: String = "", count: Int = 1)
    {
        self.id = id
        self.time = max(0, time)
        self.mode = mode
        self.fontSize = fontSize
        self.color = color
        // Comments are drawn on one line; Bilibili uses both real newlines and a literal "/n".
        self.text = text.replacingOccurrences(of: "/n", with: " ").replacingOccurrences(of: "\n", with: " ")
        self.weight = weight
        self.senderHash = senderHash
        self.count = count
    }

    public var isColored: Bool { color & 0xFFFFFF != 0xFFFFFF }

    /// Bilibili mode numbers: 1–3 scroll, 4 bottom, 5 top; 6 (reverse), 7 (advanced), 8 (code), 9 (BAS) aren't rendered.
    static func mode(_ raw: Int) -> Mode? {
        switch raw {
        case 0 ... 3: return .scroll // 0 = field omitted (proto3 default) → normal scroll
        case 4: return .bottom
        case 5: return .top
        default: return nil
        }
    }
}

public enum DanmakuParser {
    /// Segment protobuf (`/x/v2/dm/wbi/web/seg.so`): DmSegMobileReply { repeated DanmakuElem elems = 1; }.
    /// DanmakuElem: 1 id, 2 progress(ms), 3 mode, 4 fontsize, 5 color, 6 midHash, 7 content, 9 weight.
    public static func parseSegment(_ data: Data) throws -> [Danmaku] {
        var out: [Danmaku] = []
        var reader = ProtoReader(data)
        while let (field, value) = try reader.next() {
            guard field == 1, case let .bytes(elem) = value else { continue }
            var e = ProtoReader(elem)
            var id: Int64 = 0, progress = 0, mode = 1, size = 25, weight = 0
            var color: UInt32 = 0xFFFFFF
            var hash = "", text = ""
            while let (f, v) = try e.next() {
                switch (f, v) {
                case let (1, .varint(x)): id = Int64(bitPattern: x)
                case let (2, .varint(x)): progress = Int(Int32(truncatingIfNeeded: x))
                case let (3, .varint(x)): mode = Int(truncatingIfNeeded: x)
                case let (4, .varint(x)): size = Int(min(x, 100))
                case let (5, .varint(x)): color = UInt32(truncatingIfNeeded: x)
                case let (6, .bytes(b)): hash = String(decoding: b, as: UTF8.self)
                case let (7, .bytes(b)): text = String(decoding: b, as: UTF8.self)
                case let (9, .varint(x)): weight = Int(min(x, 100))
                default: break
                }
            }
            guard let m = Danmaku.mode(mode), !text.isEmpty else { continue }
            out.append(Danmaku(id: id, time: Double(progress) / 1000, mode: m, fontSize: size, color: color,
                               text: text, weight: weight, senderHash: hash))
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Legacy XML (`/x/v1/dm/list.so`): `<d p="time,mode,size,color,ctime,pool,hash,id,weight">text</d>`.
    public static func parseXML(_ data: Data) -> [Danmaku] {
        let xml = String(decoding: data, as: UTF8.self)
        var out: [Danmaku] = []
        let pattern = try! NSRegularExpression(pattern: #"<d p="([^"]*)">([^<]*)</d>"#)
        for match in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let pr = Range(match.range(at: 1), in: xml), let tr = Range(match.range(at: 2), in: xml) else { continue }
            let p = xml[pr].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 8, let time = Double(p[0]), let m = Danmaku.mode(Int(p[1]) ?? 1) else { continue }
            let text = BiliText.plain(String(xml[tr]))
            guard !text.isEmpty else { continue }
            out.append(Danmaku(id: Int64(p[7]) ?? 0, time: time, mode: m, fontSize: Int(p[2]) ?? 25,
                               color: UInt32(p[3]) ?? 0xFFFFFF, text: text,
                               weight: p.count > 8 ? Int(p[8]) ?? 10 : 10, senderHash: p[6]))
        }
        return out.sorted { $0.time < $1.time }
    }
}

/// Blocking rules (屏蔽).
public struct DanmakuFilter: Sendable {
    public var minWeight = 0
    public var showScroll = true
    public var showTop = true
    public var showBottom = true
    public var showColored = true
    /// Lowercased keywords.
    public var blockedWords: [String] = [] {
        didSet { blockedWords = Self.unique(blockedWords.map { $0.lowercased() }.filter { !$0.isEmpty }) }
    }

    /// Regex sources; compiled once (see `regexes`), invalid ones dropped.
    public var blockedPatterns: [String] = [] {
        didSet {
            blockedPatterns = Self.unique(blockedPatterns)
            regexes = RegexBox(blockedPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) })
        }
    }

    public var blockedSenders: Set<String> = []
    private var regexes = RegexBox([])
    /// 0–1: fraction of comments kept (sampled by id, so the same ones show on every replay).
    public var density = 1.0

    public init() {}

    public func allows(_ d: Danmaku) -> Bool {
        if d.weight < minWeight { return false }
        switch d.mode {
        case .scroll where !showScroll, .top where !showTop, .bottom where !showBottom: return false
        default: break
        }
        if !showColored, d.isColored { return false }
        if density < 1, Double(UInt64(bitPattern: d.id) % 1000) >= density * 1000 { return false }
        if blockedSenders.contains(d.senderHash) { return false }
        let lower = d.text.lowercased()
        if blockedWords.contains(where: { lower.contains($0) }) { return false }
        if !regexes.list.isEmpty {
            let range = NSRange(d.text.startIndex..., in: d.text)
            if regexes.list.contains(where: { $0.firstMatch(in: d.text, range: range) != nil }) { return false }
        }
        return true
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Adds the account's cloud block list (`/x/dm/filter/user`: type 0 keyword, 1 regex, 2 sender hash).
    /// Idempotent: applying the same rules twice doesn't duplicate them.
    public mutating func addAccountRules(_ rules: [JSON]) {
        var words = blockedWords, patterns = blockedPatterns
        for rule in rules {
            var text = rule["filter"].stringValue
            guard !text.isEmpty else { continue }
            switch rule["type"].intValue {
            case 0: words.append(text)
            case 1:
                // The web UI stores regex rules as "/pattern/".
                if text.count > 2, text.hasPrefix("/"), text.hasSuffix("/") { text = String(text.dropFirst().dropLast()) }
                if (try? NSRegularExpression(pattern: text)) != nil { patterns.append(text) }
            case 2: blockedSenders.insert(text)
            default: break
            }
        }
        blockedWords = words
        blockedPatterns = patterns
    }
}

/// NSRegularExpression is immutable and thread-safe.
private struct RegexBox: @unchecked Sendable {
    let list: [NSRegularExpression]
    init(_ list: [NSRegularExpression]) {
        self.list = list
    }
}

public enum DanmakuMerger {
    /// 弹幕聚合: identical text (ignoring case/whitespace) within `window` seconds of the first
    /// occurrence collapses into that one, with `count` = how many.
    public static func merge(_ sorted: [Danmaku], window: Double = 15) -> [Danmaku] {
        var out: [Danmaku] = []
        var open: [String: Int] = [:] // normalized text → index in out
        for d in sorted {
            let key = key(d)
            if let i = open[key], d.time - out[i].time <= window {
                out[i].count += 1
            } else {
                open[key] = out.count
                out.append(d)
            }
        }
        return out
    }

    static func key(_ d: Danmaku) -> String {
        "\(d.mode)|" + d.text.lowercased().filter { !$0.isWhitespace }
    }
}

/// Time-ordered danmaku for one video page, loaded in 6-minute segments as playback proceeds.
public struct DanmakuTimeline: Sendable {
    public static let segmentLength: Double = 360

    public private(set) var items: [Danmaku] = []
    public private(set) var loadedSegments: Set<Int> = []

    public init() {}

    public static func segment(for time: Double) -> Int { Int(max(0, time) / segmentLength) + 1 }

    /// Adds a segment's (sorted) items. With `mergeWindow`, repeats of comments already in the
    /// timeline within the window (e.g. across a segment boundary) fold into the existing ones.
    public mutating func add(_ new: [Danmaku], segment: Int, mergeWindow: Double? = nil) {
        loadedSegments.insert(segment)
        guard !new.isEmpty else { return }
        var incoming = new
        if let window = mergeWindow, let first = incoming.first?.time {
            var recent: [String: Int] = [:]
            var i = items.count - 1
            // Only what came just before this segment: a later segment already loaded (seeked ahead, then back)
            // isn't a repeat of these.
            while i >= 0, items[i].time > first { i -= 1 }
            while i >= 0, items[i].time >= first - window {
                recent[DanmakuMerger.key(items[i])] = recent[DanmakuMerger.key(items[i])] ?? i
                i -= 1
            }
            incoming = incoming.filter { d in
                guard let j = recent[DanmakuMerger.key(d)], case let gap = d.time - items[j].time, gap >= 0, gap <= window
                else { return true }
                items[j].count += d.count
                return false
            }
        }
        // Segments are disjoint and usually arrive in order: append when possible, else merge.
        if let last = items.last, let first = incoming.first, first.time < last.time {
            items = Self.mergeSorted(items, incoming)
        } else {
            items += incoming
        }
    }

    /// Drops items the filter now rejects (e.g. account rules arrived after loading).
    public mutating func filter(_ isIncluded: (Danmaku) -> Bool) {
        items.removeAll { !isIncluded($0) }
    }

    private static func mergeSorted(_ a: [Danmaku], _ b: [Danmaku]) -> [Danmaku] {
        var out: [Danmaku] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i].time <= b[j].time { out.append(a[i]); i += 1 } else { out.append(b[j]); j += 1 }
        }
        return out + a[i...] + b[j...]
    }

    /// Items with `from < time <= to`.
    public func due(from: Double, to: Double) -> ArraySlice<Danmaku> {
        guard to > from else { return [] }
        return items[firstIndex(after: from) ..< firstIndex(after: to)]
    }

    private func firstIndex(after t: Double) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Lane assignment for danmaku, independent of rendering. Scrolling comments cross the screen in
/// `scrollDuration` seconds (longer text moves faster); a lane is reused only once the previous
/// comment has fully entered and can't be caught before it leaves.
public struct DanmakuLayout: Sendable {
    public struct Placement: Equatable, Sendable {
        public var lane: Int
        public var mode: Danmaku.Mode
    }

    public var width: Double
    public var lanes: Int
    public var scrollDuration: Double
    public var fixedDuration: Double
    public var gap: Double

    private var scrollLanes: [(start: Double, width: Double)?]
    private var topLanes: [Double]
    private var bottomLanes: [Double]

    public init(width: Double, lanes: Int, scrollDuration: Double = 9, fixedDuration: Double = 4, gap: Double = 24) {
        self.width = width
        self.lanes = max(1, lanes)
        self.scrollDuration = scrollDuration
        self.fixedDuration = fixedDuration
        self.gap = gap
        scrollLanes = Array(repeating: nil, count: max(1, lanes))
        topLanes = Array(repeating: -.infinity, count: max(1, lanes))
        bottomLanes = Array(repeating: -.infinity, count: max(1, lanes))
    }

    public func speed(forWidth w: Double) -> Double { (width + w) / scrollDuration }

    /// x of a scrolling comment's left edge at `now`.
    public func x(start: Double, textWidth: Double, now: Double) -> Double {
        width - (now - start) * speed(forWidth: textWidth)
    }

    /// Picks a lane for a comment appearing at `now`, or nil to drop it (screen full).
    public mutating func place(_ mode: Danmaku.Mode, textWidth w: Double, now: Double) -> Placement? {
        switch mode {
        case .scroll:
            for lane in 0 ..< lanes {
                guard let prev = scrollLanes[lane] else {
                    scrollLanes[lane] = (now, w)
                    return Placement(lane: lane, mode: .scroll)
                }
                let prevSpeed = speed(forWidth: prev.width)
                let entered = (now - prev.start) * prevSpeed >= prev.width + gap
                // The previous one leaves the left edge before the new head gets there.
                let prevGone = prev.start + scrollDuration
                let newArrives = now + width / speed(forWidth: w)
                if entered, prevGone <= newArrives {
                    scrollLanes[lane] = (now, w)
                    return Placement(lane: lane, mode: .scroll)
                }
            }
            return nil
        case .top:
            guard let lane = topLanes.firstIndex(where: { $0 <= now }) else { return nil }
            topLanes[lane] = now + fixedDuration
            return Placement(lane: lane, mode: .top)
        case .bottom:
            guard let lane = bottomLanes.firstIndex(where: { $0 <= now }) else { return nil }
            bottomLanes[lane] = now + fixedDuration
            return Placement(lane: lane, mode: .bottom)
        }
    }
}

// MARK: Minimal protobuf reader (only what danmaku needs)

struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed
    }

    enum ProtoError: Error { case truncated, badWireType }

    private let data: Data
    private var i: Int

    init(_ data: Data) {
        self.data = data
        i = data.startIndex
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < data.endIndex, shift < 64 else { throw ProtoError.truncated }
            let byte = data[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
    }

    mutating func next() throws -> (Int, Value)? {
        guard i < data.endIndex else { return nil }
        let key = try varint()
        let field = Int(key >> 3)
        switch key & 7 {
        case 0: return (field, .varint(try varint()))
        case 2:
            guard let length = Int(exactly: try varint()), length <= data.endIndex - i else { throw ProtoError.truncated }
            defer { i += length }
            return (field, .bytes(data.subdata(in: i ..< i + length)))
        case 1:
            guard i + 8 <= data.endIndex else { throw ProtoError.truncated }
            i += 8
            return (field, .fixed)
        case 5:
            guard i + 4 <= data.endIndex else { throw ProtoError.truncated }
            i += 4
            return (field, .fixed)
        default: throw ProtoError.badWireType
        }
    }
}

/// Decides, frame by frame, which comments are due — and when the jump in media time means a seek.
///
/// A seek is any change that doesn't match the expected advance (`rate × frame interval`): jumps
/// backwards, jumps forward, or movement while paused. After a seek nothing is backfilled except
/// comments at the exact landing point, so scrubbing never floods the screen.
public struct DanmakuClock: Sendable {
    public enum Step: Equatable, Sendable {
        /// Nothing new (paused, or first frame not ready).
        case idle
        /// Show comments with `from < time <= to`.
        case window(from: Double, to: Double)
        /// Clear the screen, then show comments with `from < time <= to` (the landing point).
        case seek(from: Double, to: Double)
    }

    public var lastTime: Double?
    /// Allowed deviation from the expected advance before a jump counts as a seek.
    public var tolerance: Double

    public init(tolerance: Double = 0.5) {
        self.tolerance = tolerance
    }

    public mutating func advance(to now: Double, rate: Double, elapsed: Double) -> Step {
        defer { lastTime = now }
        guard let last = lastTime else { return .seek(from: now - 0.1, to: now) }
        let delta = now - last
        if delta == 0 { return .idle }
        let expected = rate * elapsed
        if delta < -0.05 || abs(delta - expected) > tolerance + abs(expected) * 0.5 || (rate == 0 && abs(delta) > 0.05) {
            return .seek(from: now - 0.1, to: now)
        }
        return delta > 0 ? .window(from: last, to: now) : .idle
    }

    public mutating func reset() {
        lastTime = nil
    }
}

public enum SubtitleLookup {
    /// The line showing at `time` (lines sorted by `from`), by binary search.
    public static func line(at time: Double, in lines: [API.SubtitleLine]) -> API.SubtitleLine? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].from <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let line = lines[lo - 1]
        return time < line.to ? line : nil
    }
}
