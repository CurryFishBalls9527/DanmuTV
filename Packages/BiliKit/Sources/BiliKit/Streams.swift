import Foundation

public struct StreamPreferences: Sendable {
    /// Preferred `codecid` (7 AVC, 12 HEVC, 13 AV1). Falls back when the video lacks it.
    public var preferredCodec: Int
    /// Codecs the device can decode in hardware.
    public var supportedCodecs: Set<Int>
    /// Highest qn to offer (0 = no cap).
    public var maxQuality: Int
    /// Offer only the single best variant instead of a bandwidth ladder.
    public var onlyHighest: Bool
    /// 过滤 60 帧以上: drop high-frame-rate variants (Bilibili's 60 fps qn 74/116) for TVs that stutter on them.
    public var filterHighFramerate: Bool
    /// HDR10 (qn 125) when the display path supports it.
    public var allowHDR: Bool
    /// Dolby Vision (qn 126) when the device supports it.
    public var allowDolbyVision: Bool
    public var preferDolbyAudio: Bool
    /// FLAC (Hi-Res 无损) when the video has it and Dolby isn't chosen.
    public var preferLosslessAudio: Bool
    /// A quality the user picked manually; overrides adaptive selection.
    public var manualQuality: Int?

    public init(preferredCodec: Int = 12, supportedCodecs: Set<Int> = [7, 12], maxQuality: Int = 0, onlyHighest: Bool = false,
                filterHighFramerate: Bool = false, allowHDR: Bool = false, allowDolbyVision: Bool = false,
                preferDolbyAudio: Bool = true, preferLosslessAudio: Bool = false, manualQuality: Int? = nil)
    {
        self.allowDolbyVision = allowDolbyVision
        self.preferLosslessAudio = preferLosslessAudio
        self.preferredCodec = preferredCodec
        self.supportedCodecs = supportedCodecs
        self.maxQuality = maxQuality
        self.onlyHighest = onlyHighest
        self.filterHighFramerate = filterHighFramerate
        self.allowHDR = allowHDR
        self.preferDolbyAudio = preferDolbyAudio
        self.manualQuality = manualQuality
    }
}

public struct StreamSelection: Equatable, Sendable {
    /// Video variants of one codec family, best first. AVPlayer switches between them by bandwidth.
    public var videos: [DashStream]
    public var audio: DashStream
    public var audioIsAtmos = false

    public init(videos: [DashStream], audio: DashStream, audioIsAtmos: Bool = false) {
        self.videos = videos
        self.audio = audio
        self.audioIsAtmos = audioIsAtmos
    }

    public var hasHDR: Bool { videos.contains(where: \.isHDR) }
}

public enum StreamSelector {
    static let codecFallbackOrder = [12, 7, 13]
    /// Anything above this counts as high frame rate (Bilibili offers 24/25/30 and 50/60).
    static let highFrameRateThreshold = 40.0

    public static func select(_ info: PlayInfo, _ prefs: StreamPreferences) -> StreamSelection? {
        var candidates = info.videos.filter { prefs.supportedCodecs.contains($0.codecID) }
        if prefs.filterHighFramerate { candidates.removeAll { $0.frameRate > highFrameRateThreshold } }
        // HDR is mostly 4K: offered only when the cap allows 4K.
        if prefs.maxQuality > 0 { candidates.removeAll { $0.isHDR ? prefs.maxQuality < 120 : $0.id > prefs.maxQuality } }
        // HDR / DV are a separate rung on top of an SDR ladder: the player starts on the HDR variant
        // when the display supports it and can always fall back to SDR.
        let hdrCandidates = candidates.filter { s in
            s.isHDR && (s.isDolbyVision ? prefs.allowDolbyVision : prefs.allowHDR)
        }
        candidates.removeAll(where: \.isHDR)

        // One codec family per master playlist keeps ABR switches seamless.
        let order = [prefs.preferredCodec] + codecFallbackOrder.filter { $0 != prefs.preferredCodec }
        let best = Dictionary(grouping: candidates, by: \.codecID).mapValues { $0.map(\.id).max() ?? 0 }
        guard let top = best.values.max() else { return nil }
        // A preferred HEVC/AV1 family that tops out lower than another family (Bilibili transcodes
        // HEVC late, so new uploads may have AVC 1080P but HEVC only 480P) loses to the better one.
        // An explicit AVC preference is honoured as-is: users pick it for compatibility.
        let family: Int
        if let preferredBest = best[prefs.preferredCodec], preferredBest == top || prefs.preferredCodec == 7 {
            family = prefs.preferredCodec
        } else {
            guard let f = order.first(where: { best[$0] == top }) else { return nil }
            family = f
        }
        candidates = candidates.filter { $0.codecID == family }
        // HDR/DV are HEVC: only stacked on an HEVC ladder (one codec family per master).
        // Dolby Vision is preferred when allowed; a manual pick of a specific HDR id wins.
        let hdrSameFamily = hdrCandidates.filter { $0.codecID == family }
        let hdr = prefs.manualQuality.flatMap { m in hdrSameFamily.filter { $0.id == m }.max { $0.bandwidth < $1.bandwidth } }
            ?? hdrSameFamily.max { ($0.isDolbyVision ? 1 : 0, $0.bandwidth) < ($1.isDolbyVision ? 1 : 0, $1.bandwidth) }

        // Best stream per quality id, highest quality first.
        var bestPerID: [Int: DashStream] = [:]
        for s in candidates where (bestPerID[s.id]?.bandwidth ?? -1) < s.bandwidth {
            bestPerID[s.id] = s
        }
        var videos = bestPerID.values.sorted { ($0.id, $0.bandwidth) > ($1.id, $1.bandwidth) }

        if let manual = prefs.manualQuality {
            if let hdr, hdr.id == manual {
                videos = [hdr]
            } else {
                // The exact quality, or the best one below it; if none, stay adaptive.
                let picked = videos.drop { $0.id > manual }.prefix(1)
                if !picked.isEmpty { videos = Array(picked) }
            }
        } else {
            if prefs.onlyHighest { videos = Array(videos.prefix(1)) }
            if let hdr { videos.insert(hdr, at: 0) }
        }
        guard !videos.isEmpty else { return nil }

        let dolby = prefs.preferDolbyAudio ? info.dolbyAudios.max { $0.bandwidth < $1.bandwidth } : nil
        let flac = prefs.preferLosslessAudio ? info.flacAudio : nil
        guard let audio = dolby ?? flac ?? info.audios.max(by: { $0.bandwidth < $1.bandwidth }) else { return nil }
        return StreamSelection(videos: videos, audio: audio, audioIsAtmos: dolby != nil && info.dolbyIsAtmos)
    }
}

/// CDN host handling (CDN 策略).
public enum CDN {
    /// MCDN / PCDN (peer or edge caches) are the usual cause of stalls and "server not found" errors.
    public static func isPCDN(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return false }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return true } // bare IPv4
        if host.contains("mcdn.bilivideo") || host.hasSuffix("szbdyd.com") { return true }
        if let port = components.port, port != 443, port != 80 { return true }
        return false
    }

    /// Orders candidate URLs. With `preferOfficial`, official upos/akamai mirrors come first
    /// and MCDN/PCDN last; otherwise the server's order is kept.
    public static func ordered(_ urls: [String], preferOfficial: Bool) -> [String] {
        ordered(urls, policy: CDNPolicy(preferOfficial: preferOfficial), badHosts: [])
    }
}

public enum HLSPlaylist {
    /// DASH `bandwidth` is an average; HLS BANDWIDTH is a peak. Declaring the average makes AVPlayer
    /// see every segment as "over budget" and mis-steer ABR, so declare ~1.5× as the peak.
    static func peak(_ average: Int) -> Int { average * 3 / 2 }

    /// Master playlist. With `mirrors > 1` every variant is listed once per CDN mirror (HLS redundant
    /// streams), each mirror with its own audio group, so AVPlayer fails over to the next mirror by itself
    /// when one stops serving mid-playback.
    ///
    /// `iFrameVariant` adds an I-frame stream (that variant's segments) so the tvOS scrubber can show
    /// thumbnails: the system transport bar only takes thumbnails from HLS I-frame playlists.
    public static func master(_ selection: StreamSelection, mirrors: Int = 1,
                              iFrameVariant: Int? = nil, iFrameURI: String? = nil,
                              startVariant: Int? = nil,
                              attributes: (Int) -> (codecs: String, supplemental: String?, range: String)? = { _ in nil },
                              videoURI: (_ variant: Int, _ mirror: Int) -> String,
                              audioURI: (_ mirror: Int) -> String) -> String
    {
        // The first listed variant is where AVPlayer starts.
        var order = Array(selection.videos.indices)
        if let s = startVariant, order.contains(s) { order.removeAll { $0 == s }; order.insert(s, at: 0) }
        let audio = selection.audio
        let isDolby = audio.codecs.hasPrefix("ec-3")
        let isFLAC = audio.codecs.lowercased().hasPrefix("flac")
        let audioCodecs = isFLAC ? "fLaC" : audio.codecs
        let (name, channels) = isDolby ? (selection.audioIsAtmos ? ("杜比全景声", "16/JOC") : ("杜比音效", "6"))
            : (isFLAC ? ("无损", "2") : ("立体声", "2"))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for m in 0 ..< max(1, mirrors) {
            lines.append(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud\#(m)",NAME="\#(name)",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="\#(channels)",URI="\#(audioURI(m))""#)
        }
        for m in 0 ..< max(1, mirrors) {
            for i in order {
                let v = selection.videos[i]
                let hls = attributes(i) ?? v.hlsVideo
                var attrs = [
                    "BANDWIDTH=\(peak(v.bandwidth + audio.bandwidth))",
                    "AVERAGE-BANDWIDTH=\(v.bandwidth + audio.bandwidth)",
                    #"CODECS="\#(hls.codecs),\#(audioCodecs)""#,
                    "RESOLUTION=\(v.width)x\(v.height)",
                    #"AUDIO="aud\#(m)""#,
                    "VIDEO-RANGE=\(hls.range)",
                ]
                if let supplemental = hls.supplemental { attrs.append(#"SUPPLEMENTAL-CODECS="\#(supplemental)""#) }
                if v.frameRate > 0 { attrs.append(String(format: "FRAME-RATE=%.3f", v.frameRate)) }
                lines.append("#EXT-X-STREAM-INF:" + attrs.joined(separator: ","))
                lines.append(videoURI(i, m))
            }
        }
        if let i = iFrameVariant, selection.videos.indices.contains(i) {
            let v = selection.videos[i]
            let hls = attributes(i) ?? v.hlsVideo
            lines.append(#"#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\#(peak(v.bandwidth)),CODECS="\#(hls.codecs)",RESOLUTION=\#(v.width)x\#(v.height),VIDEO-RANGE=\#(hls.range),URI="\#(iFrameURI ?? videoURI(i, 0))""#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Media playlist addressing byte ranges of one fMP4 file. `iFramesOnly` makes it the I-frame
    /// playlist for scrubbing thumbnails: each fragment starts with a keyframe, and AVFoundation
    /// decodes that first frame (whole fragments of the lowest variant are small).
    public static func media(_ stream: DashStream, url: String, index: SegmentIndex, iFramesOnly: Bool = false) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(index.maxDuration.rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            iFramesOnly ? "#EXT-X-I-FRAMES-ONLY" : "#EXT-X-INDEPENDENT-SEGMENTS",
            #"#EXT-X-MAP:URI="\#(url)",BYTERANGE="\#(stream.initRange.count)@\#(stream.initRange.lowerBound)""#,
        ]
        for segment in index.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
