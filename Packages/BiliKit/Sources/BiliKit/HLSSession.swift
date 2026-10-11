import Foundation

/// Generates the HLS playlists for one DASH selection: a master playlist with redundant per-mirror
/// variants, and media playlists built on demand from each track's sidx.
///
/// Platform-independent so the playlist/failover logic is unit-testable; the app's
/// `DashResourceLoader` only adapts it to `AVAssetResourceLoaderDelegate`.
public final class HLSSession: @unchecked Sendable {
    public typealias RangeFetcher = @Sendable (_ url: URL, _ range: ClosedRange<Int>) async throws -> Data

    public let selection: StreamSelection
    /// Number of redundant CDN mirrors listed in the master playlist.
    public let mirrors: Int
    private let fetch: RangeFetcher
    /// Track key ("v0", "a") → candidate URLs in CDN preference order.
    private let trackURLs: [String: [String]]

    private let lock = NSLock()
    private var indexes: [String: SegmentIndex] = [:]
    private var inflight: [String: Task<SegmentIndex, Error>] = [:]
    private var _hosts: [String: String] = [:]
    /// URL that actually served each track's index (single-mirror playlists point there).
    private var servedURLs: [String: String] = [:]
    /// Parsed init segments of HDR/DV variants (variant index -> info).
    private var initInfo: [Int: VideoInitInfo] = [:]
    private var _lastError: String?

    public static let maxMirrors = 3
    /// 快速加载模式: a single mirror and no thumbnail stream, so playback starts with the fewest requests.
    public let fastLoad: Bool

    public convenience init(selection: StreamSelection, preferOfficialCDN: Bool, fetch: @escaping RangeFetcher) {
        self.init(selection: selection, policy: CDNPolicy(preferOfficial: preferOfficialCDN), fastLoad: false, fetch: fetch)
    }

    public init(selection: StreamSelection, policy: CDNPolicy, fastLoad: Bool, fetch: @escaping RangeFetcher) {
        self.selection = selection
        self.fetch = fetch
        self.fastLoad = fastLoad
        var urls: [String: [String]] = ["a": CDN.ordered(selection.audio.urls, policy: policy)]
        for (i, v) in selection.videos.enumerated() {
            urls["v\(i)"] = CDN.ordered(v.urls, policy: policy)
        }
        trackURLs = urls
        mirrors = fastLoad ? 1 : max(1, min(Self.maxMirrors, urls.values.map(\.count).min() ?? 1))
    }

    /// Candidate URLs per track, for the debug panel.
    public var candidates: [String: [String]] { trackURLs }

    /// URL a track's segments come from for a given mirror (debug panel).
    public func segmentURL(track: String, mirror: Int) -> String? {
        if mirrors == 1 { return lock.withLock { servedURLs[track] } ?? trackURLs[track]?.first }
        return trackURLs[track].flatMap { $0.indices.contains(mirror) ? $0[mirror] : nil }
    }

    /// Host that served each track's index, for errors and the debug panel.
    public var hosts: [String: String] { lock.withLock { _hosts } }
    public var lastError: String? { lock.withLock { _lastError } }

    /// Index of the lowest SDR variant (thumbnails come from it).
    var thumbnailVariant: Int? { selection.videos.lastIndex { !$0.isHDR } }

    /// Fast load starts on a mid-quality SDR variant (<= 1080P) instead of the top one.
    var startVariant: Int? {
        guard fastLoad else { return nil }
        return selection.videos.firstIndex { !$0.isHDR && $0.height <= 1080 }
    }

    /// Reads the init segments of HDR/DV variants so the master declares the right codec strings and
    /// VIDEO-RANGE (Dolby Vision compatibility and PQ vs HLG are only in the file, not the API).
    public func prepare() async {
        for (i, v) in selection.videos.enumerated() where v.isHDR {
            for candidate in trackURLs["v\(i)"] ?? [] {
                guard let url = URL(string: candidate), let data = try? await fetch(url, v.initRange),
                      let info = MP4Init.parse(data) else { continue }
                lock.withLock { initInfo[i] = info }
                Log.player.info("v\(i) init: \(info.sampleEntry, privacy: .public) dv=\(info.dvProfile ?? -1).\(info.dvCompatibility ?? -1) transfer=\(info.transfer ?? -1)")
                break
            }
        }
    }

    /// Resolved HLS attributes for a variant (parsed init when available, API heuristics otherwise).
    public func attributes(variant i: Int) -> (codecs: String, supplemental: String?, range: String) {
        let v = selection.videos[i]
        if let info = lock.withLock({ initInfo[i] }) { return info.hls(fallbackCodecs: v.codecs) }
        return v.hlsVideo
    }

    public func isDolbyVision(variant i: Int) -> Bool {
        lock.withLock { initInfo[i]?.isDolbyVision } ?? selection.videos[i].isDolbyVision
    }

    public func masterPlaylist(scheme: String) -> String {
        HLSPlaylist.master(selection, mirrors: mirrors, iFrameVariant: thumbnailVariant,
                           iFrameURI: "\(scheme)://play/iframe.m3u8",
                           startVariant: startVariant,
                           attributes: { self.attributes(variant: $0) },
                           videoURI: { "\(scheme)://play/v\($0)m\($1).m3u8" },
                           audioURI: { "\(scheme)://play/am\($0).m3u8" })
    }

    /// Media playlist for a name like "v0m1" (variant 0, mirror 1) or "am0" (audio, mirror 0).
    public func mediaPlaylist(named name: String) async throws -> String {
        if name == "iframe" {
            // Thumbnails come from the lowest SDR variant.
            guard let i = thumbnailVariant else { throw URLError(.fileDoesNotExist) }
            let stream = selection.videos[i]
            let index = try await segmentIndex("v\(i)", stream: stream, startingAt: 0)
            guard let url = lock.withLock({ servedURLs["v\(i)"] }) ?? trackURLs["v\(i)"]?.first else { throw URLError(.fileDoesNotExist) }
            return HLSPlaylist.media(stream, url: url, index: index, iFramesOnly: true)
        }
        guard let split = name.lastIndex(of: "m"), let mirror = Int(name[name.index(after: split)...]) else {
            throw URLError(.fileDoesNotExist)
        }
        let track = String(name[..<split])
        guard let urls = trackURLs[track], urls.indices.contains(mirror), let stream = stream(track) else {
            throw URLError(.fileDoesNotExist)
        }
        let index = try await segmentIndex(track, stream: stream, startingAt: mirror)
        // With redundant mirrors, segments point at this mirror and AVPlayer fails over between
        // variants. With a single mirror, point at whichever host actually answered.
        let url = mirrors == 1 ? (lock.withLock { servedURLs[track] } ?? urls[mirror]) : urls[mirror]
        return HLSPlaylist.media(stream, url: url, index: index)
    }

    private func stream(_ track: String) -> DashStream? {
        if track == "a" { return selection.audio }
        guard track.hasPrefix("v"), let i = Int(track.dropFirst()), selection.videos.indices.contains(i) else { return nil }
        return selection.videos[i]
    }

    /// The sidx is identical on every mirror: fetch it once per track (deduplicating concurrent
    /// requests), trying the requested mirror first and then the others. Failures aren't cached.
    private func segmentIndex(_ track: String, stream: DashStream, startingAt mirror: Int) async throws -> SegmentIndex {
        let task: Task<SegmentIndex, Error> = lock.withLock {
            if let cached = indexes[track] { return Task { cached } }
            if let running = inflight[track] { return running }
            let urls = trackURLs[track] ?? []
            let ordered = Array(urls[mirror...]) + Array(urls[..<mirror])
            let task = Task { try await self.fetchIndex(track, stream: stream, urls: ordered) }
            inflight[track] = task
            return task
        }
        do {
            let index = try await task.value
            lock.withLock {
                indexes[track] = index
                inflight[track] = nil
            }
            return index
        } catch {
            lock.withLock { inflight[track] = nil }
            throw error
        }
    }

    private func fetchIndex(_ track: String, stream: DashStream, urls: [String]) async throws -> SegmentIndex {
        var failures: [String] = []
        for candidate in urls {
            guard let url = URL(string: candidate) else { continue }
            do {
                let data = try await fetch(url, stream.indexRange)
                let index = try SegmentIndex(data: data, boxEnd: stream.indexRange.upperBound)
                lock.withLock {
                    _hosts[track] = url.host ?? ""
                    servedURLs[track] = candidate
                }
                Log.player.info("track \(track, privacy: .public) index via \(url.host ?? "?", privacy: .public), \(index.segments.count) segments")
                return index
            } catch {
                if BiliClient.isCancellation(error) { throw error }
                if CDNHealth.isCertificateError(error), let host = url.host { CDNHealth.shared.markBad(host) }
                failures.append("\(url.host ?? "?"): \(error.localizedDescription)")
                Log.player.error("sidx failed on \(url.host ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let message = "所有 CDN 线路均无法访问\n" + failures.joined(separator: "\n")
        lock.withLock { _lastError = message }
        throw NSError(domain: "DanmuTV.CDN", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Small playback decisions, kept pure for testing.
public enum PlaybackPolicy {
    /// 继续播放: resume from history only for this page, ignoring records under 5s and at the very end.
    public static func resumePosition(lastPlayTime: Double, lastPlayCID: Int, cid: Int, duration: Double, enabled: Bool) -> Double? {
        guard enabled,
              lastPlayCID == 0 || lastPlayCID == cid,
              lastPlayTime > 5,
              duration <= 0 || lastPlayTime < duration - 5
        else { return nil }
        return lastPlayTime
    }

    /// For the main 播放 button on a multi-P video: the page the user was last watching, if not `current`.
    public static func resumePage(lastPlayCID: Int, pages: [VideoPage], current: Int) -> Int? {
        guard lastPlayCID != 0, let index = pages.firstIndex(where: { $0.cid == lastPlayCID }), index != current else { return nil }
        return index
    }

    /// Report every `interval` seconds of playback, and again after seeking backwards.
    public static func shouldReport(second: Int, lastReported: Int, interval: Int, isPlaying: Bool) -> Bool {
        isPlaying && second > 0 && (second - lastReported >= interval || second < lastReported)
    }

    /// Show 即将播放 during the last `leadTime` seconds when continuous play will advance.
    public static func isUpNext(position: Double, duration: Double, hasNext: Bool, autoPlay: Bool, leadTime: Double) -> Bool {
        hasNext && autoPlay && duration.isFinite && duration > 0 && position.isFinite && duration - position <= leadTime
    }
}
