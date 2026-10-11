import Foundation

/// What the init segment (moov) says about a video track — the only reliable source for
/// Dolby Vision profile/compatibility and HDR transfer function.
public struct VideoInitInfo: Equatable, Sendable {
    /// Sample entry four-cc: hvc1, hev1, dvh1, dvhe, avc1, av01…
    public var sampleEntry: String
    /// From dvcC/dvvC.
    public var dvProfile: Int?
    public var dvLevel: Int?
    /// dv_bl_signal_compatibility_id: 0 none (profile 5), 1 HDR10/PQ, 2 SDR, 4 HLG.
    public var dvCompatibility: Int?
    /// colr nclx transfer_characteristics: 1 BT.709, 16 PQ, 18 HLG.
    public var transfer: Int?
    /// hvcC general_level_idc (e.g. 153 = level 5.1).
    public var hevcLevel: Int?
    /// hvcC general_profile_idc (2 = Main 10).
    public var hevcProfile: Int?

    public var isDolbyVision: Bool { dvProfile != nil }

    /// HLS attributes per Apple's HLS Authoring Specification.
    public func hls(fallbackCodecs: String) -> (codecs: String, supplemental: String?, range: String) {
        let baseRange: String
        switch transfer {
        case 16: baseRange = "PQ"
        case 18: baseRange = "HLG"
        default: baseRange = "SDR"
        }
        let level = hevcLevel ?? 153
        let hevcCodecs = "hvc1.\(hevcProfile ?? 2).4.L\(level).b0"
        guard let profile = dvProfile else {
            // HDR10 / HLG / SDR HEVC: keep the stream's own codec string, range from colr.
            return (fallbackCodecs, nil, baseRange)
        }
        let dv = String(format: "dvh1.%02d.%02d", profile, dvLevel ?? 6)
        if ["hvc1", "hev1"].contains(sampleEntry) {
            // Profile 8.x: an HEVC base layer playable without DV, DV described as supplemental.
            switch dvCompatibility {
            case 4: return (hevcCodecs, dv + "/db4h", "HLG")
            case 1: return (hevcCodecs, dv + "/db1p", "PQ")
            case 2: return (hevcCodecs, dv + "/db2g", "SDR")
            default: return (hevcCodecs, nil, baseRange)
            }
        }
        // dvh1/dvhe sample entry (profile 5, DV-only): DV is the codec; range is PQ.
        return (dv, nil, "PQ")
    }
}

public enum MP4Init {
    /// Parses the first video sample entry of an init segment (ftyp + moov).
    public static func parse(_ data: Data) -> VideoInitInfo? {
        guard let stsd = find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"], in: data, range: data.startIndex ..< data.endIndex)
        else { return nil }
        // stsd: version/flags (4) + entry_count (4), then sample entries.
        let entriesStart = stsd.lowerBound + 8
        guard entriesStart + 8 <= stsd.upperBound else { return nil }
        let size = Int(u32(data, entriesStart))
        let type = fourCC(data, entriesStart + 4)
        guard size >= 8, entriesStart + size <= stsd.upperBound else { return nil }
        var info = VideoInitInfo(sampleEntry: type)
        // VisualSampleEntry fields take 78 bytes after the 8-byte box header; child boxes follow.
        let childStart = entriesStart + 8 + 78
        guard childStart <= entriesStart + size else { return info }
        for (boxType, body) in boxes(in: data, range: childStart ..< entriesStart + size) {
            switch boxType {
            case "dvcC", "dvvC", "dvwC":
                guard body.count >= 5 else { continue }
                let b2 = Int(data[body.lowerBound + 2]), b3 = Int(data[body.lowerBound + 3]), b4 = Int(data[body.lowerBound + 4])
                info.dvProfile = b2 >> 1
                info.dvLevel = ((b2 & 1) << 5) | (b3 >> 3)
                info.dvCompatibility = b4 >> 4
            case "colr":
                guard body.count >= 10, fourCC(data, body.lowerBound) == "nclx" else { continue }
                info.transfer = Int(u16(data, body.lowerBound + 6))
            case "hvcC":
                guard body.count >= 13 else { continue }
                info.hevcProfile = Int(data[body.lowerBound + 1] & 0x1F)
                info.hevcLevel = Int(data[body.lowerBound + 12])
            default:
                break
            }
        }
        return info
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// Body range of the box at `path`.
    static func find(path: [String], in data: Data, range: Range<Int>) -> Range<Int>? {
        guard let first = path.first else { return range }
        for (type, body) in boxes(in: data, range: range) where type == first {
            if path.count == 1 { return body }
            if containers.contains(type), let found = find(path: Array(path.dropFirst()), in: data, range: body) { return found }
        }
        return nil
    }

    static func boxes(in data: Data, range: Range<Int>) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = Int(u32(data, i))
            let type = fourCC(data, i + 4)
            var header = 8
            if size == 1, i + 16 <= range.upperBound {
                size = Int(clamping: (0 ..< 8).reduce(UInt64(0)) { $0 << 8 | UInt64(data[i + 8 + $1]) })
                header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, i + size <= range.upperBound else { break }
            out.append((type, i + header ..< i + size))
            i += size
        }
        return out
    }

    static func u32(_ d: Data, _ i: Int) -> UInt32 { d[i ..< i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    static func u16(_ d: Data, _ i: Int) -> UInt16 { d[i ..< i + 2].reduce(0) { $0 << 8 | UInt16($1) } }
    static func fourCC(_ d: Data, _ i: Int) -> String { String(decoding: d[i ..< i + 4], as: UTF8.self) }
}
