import Foundation

/// One DASH representation (a single video or audio track) from `playurl`.
public struct DashStream: Hashable, Sendable {
    /// Quality id (`qn`) for video, e.g. 80 = 1080P, 120 = 4K; audio ids are 302xx.
    public var id: Int
    public var codecs: String
    /// 7 = AVC, 12 = HEVC, 13 = AV1 (0 for audio).
    public var codecID: Int
    public var width: Int
    public var height: Int
    public var frameRate: Double
    /// Average bitrate in bits/s.
    public var bandwidth: Int
    /// Primary URL first, then backups.
    public var urls: [String]
    /// Byte range of the init segment (moov), inclusive.
    public var initRange: ClosedRange<Int>
    /// Byte range of the sidx box, inclusive.
    public var indexRange: ClosedRange<Int>

    public init(id: Int, codecs: String, codecID: Int, width: Int, height: Int, frameRate: Double, bandwidth: Int,
                urls: [String], initRange: ClosedRange<Int>, indexRange: ClosedRange<Int>)
    {
        self.id = id
        self.codecs = codecs
        self.codecID = codecID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bandwidth = bandwidth
        self.urls = urls
        self.initRange = initRange
        self.indexRange = indexRange
    }

    /// Parses a representation; both camelCase and snake_case keys occur in the wild.
    public init?(_ j: JSON) {
        let base = j["baseUrl"].string ?? j["base_url"].string ?? ""
        let backups = (j["backupUrl"].exists ? j["backupUrl"] : j["backup_url"]).array.compactMap(\.string)
        let seg = j["segment_base"].exists ? j["segment_base"] : j["SegmentBase"]
        guard !base.isEmpty,
              let initRange = Self.range(seg["initialization"].string ?? seg["Initialization"].stringValue),
              let indexRange = Self.range(seg["index_range"].string ?? seg["indexRange"].stringValue)
        else { return nil }
        self.init(id: j["id"].intValue,
                  codecs: j["codecs"].stringValue,
                  codecID: j["codecid"].intValue,
                  width: j["width"].intValue,
                  height: j["height"].intValue,
                  frameRate: Self.frameRate(j["frameRate"].string ?? j["frame_rate"].stringValue),
                  bandwidth: j["bandwidth"].intValue,
                  urls: [base] + backups.filter { $0 != base },
                  initRange: initRange,
                  indexRange: indexRange)
    }

    static func range(_ s: String) -> ClosedRange<Int>? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] <= parts[1] else { return nil }
        return parts[0] ... parts[1]
    }

    /// "25", "29.970" or "30000/1001".
    static func frameRate(_ s: String) -> Double {
        let parts = s.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first ?? 0
    }

    public var isHDR: Bool { id == 125 || id == 126 }
    public var isDolbyVision: Bool { id == 126 || codecs.hasPrefix("dvh1") || codecs.hasPrefix("dvhe") }

    /// HLS VIDEO-RANGE and codec strings. Dolby Vision profile 8 is HEVC with a DV layer: declare
    /// the HEVC base in CODECS and the DV profile in SUPPLEMENTAL-CODECS (db4h = HLG, db1p = PQ base).
    public var hlsVideo: (codecs: String, supplemental: String?, range: String) {
        switch codecs {
        case "dvh1.08.07", "dvh1.08.03": return ("hvc1.2.4.L153.b0", codecs + "/db4h", "HLG")
        case "dvh1.08.06": return ("hvc1.2.4.L150", codecs + "/db1p", "PQ")
        default:
            if codecs.hasPrefix("dvh1.05") || codecs.hasPrefix("dvhe.05") { return (codecs, nil, "PQ") } // profile 5: DV only
            if isDolbyVision { return (codecs, nil, "PQ") }
            if id == 125 { return (codecs, nil, "PQ") } // Bilibili "HDR 真彩" is HDR10
            return (codecs, nil, "SDR")
        }
    }
}

/// Everything `playurl` returns that playback needs.
public struct PlayInfo: Sendable {
    public var videos: [DashStream]
    public var audios: [DashStream]
    /// Dolby Digital Plus / Atmos tracks (E-AC-3), when the video has them.
    public var dolbyAudios: [DashStream]
    public var flacAudio: DashStream?
    /// dash.dolby.type: 1 杜比音效 (E-AC-3), 2 杜比全景声 (Atmos / JOC).
    public var dolbyIsAtmos: Bool
    public var duration: Double
    /// qn → display name, e.g. 80 → "1080P 高清", in the server's order (best first).
    public var qualities: [(id: Int, name: String)]
    /// Single-file fallback when the video has no DASH (old uploads).
    public var progressiveURL: String?
    public var lastPlayTime: Double
    public var lastPlayCID: Int
    public var isPreview: Bool
    /// PGC opening/ending ranges (片头/片尾).
    public var skips: [SkipRange]

    public var hasDash: Bool { !videos.isEmpty && !audios.isEmpty }

    public init(_ d: JSON) {
        let dash = d["dash"]
        videos = dash["video"].array.compactMap(DashStream.init)
        audios = dash["audio"].array.compactMap(DashStream.init)
        dolbyAudios = dash["dolby"]["audio"].array.compactMap(DashStream.init)
        flacAudio = DashStream(dash["flac"]["audio"])
        dolbyIsAtmos = dash["dolby"]["type"].intValue == 2
        duration = dash["duration"].double ?? Double(d["timelength"].intValue) / 1000
        let ids = d["accept_quality"].array.map(\.intValue)
        let names = d["accept_description"].array.map(\.stringValue)
        qualities = ids.enumerated().map { i, id in (id, names.indices.contains(i) ? names[i] : String(id)) }
        progressiveURL = d["durl"][0]["url"].string
        lastPlayTime = Double(d["last_play_time"].intValue) / 1000
        lastPlayCID = d["last_play_cid"].intValue
        isPreview = d["is_preview"].bool
        skips = SkipRange.parse(clips: d["clip_info_list"], skip: JSON(nil))
    }

    public func qualityName(_ id: Int) -> String {
        qualities.first { $0.id == id }?.name ?? Self.defaultQualityNames[id] ?? String(id)
    }

    static let defaultQualityNames: [Int: String] = [
        6: "240P", 16: "360P", 32: "480P", 64: "720P", 74: "720P60", 80: "1080P", 112: "1080P+",
        116: "1080P60", 120: "4K", 125: "HDR", 126: "杜比视界", 127: "8K",
    ]
}
