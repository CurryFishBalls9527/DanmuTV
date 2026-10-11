import Foundation

/// Pure logic for SMB local playback (kept out of the views so it can be tested).
public enum SMBAddress {
    /// Parses what a user types for a server: "nas.local", "smb://NAS:445", "192.168.1.10",
    /// "[fe80::1]". Returns host and optional port; rejects paths, users and other schemes.
    public static func parse(_ input: String) -> (host: String, port: Int?)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.range(of: "://") == nil ? "smb://" + trimmed : trimmed
        guard let c = URLComponents(string: withScheme), c.scheme?.lowercased() == "smb",
              let host = c.host, !host.isEmpty,
              c.path.isEmpty || c.path == "/", c.user == nil, c.query == nil
        else { return nil }
        let valid = host.allSatisfy { $0.isLetter || $0.isNumber || ".-:_".contains($0) }
        guard valid else { return nil }
        if let port = c.port, !(1 ... 65535).contains(port) { return nil }
        return (host.lowercased(), c.port)
    }

    /// smb:// URL for AMSMB2 (server root).
    public static func serverURL(host: String, port: Int?) -> URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host
        c.port = port
        return c.url
    }

    /// smb:// URL VLC opens: share + path, percent-encoded (spaces, CJK, #, ?, %).
    public static func mediaURL(host: String, port: Int?, share: String, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host
        c.port = port
        c.path = "/" + ([share] + path.split(separator: "/").map(String.init)).joined(separator: "/")
        return c.url
    }
}

public struct LocalEntry: Hashable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64

    public init(name: String, path: String, isDirectory: Bool, size: Int64) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public enum LocalListing {
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "flv", "ts", "m2ts", "mts", "mpg", "mpeg",
                                                      "wmv", "webm", "rmvb", "rm", "3gp", "vob"]
    /// NAS / Windows housekeeping folders that never contain the user's videos.
    static let systemFolders: Set<String> = ["$recycle.bin", "system volume information", "@eadir", "#recycle", "@recycle", ".trashes", "lost+found"]

    public static func isVideo(_ name: String) -> Bool { videoExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// Folders first, then videos, natural order ("第2集" before "第10集"); hidden/system items removed.
    public static func visible(_ entries: [LocalEntry]) -> [LocalEntry] {
        entries.filter { e in
            !e.name.hasPrefix(".") && e.name != "." && e.name != ".." && !systemFolders.contains(e.name.lowercased())
                && (e.isDirectory || isVideo(e.name))
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Sidecar files next to a video: danmaku XML and subtitle files.
public enum Sidecar {
    static let danmakuSuffixes = [".xml", ".danmaku.xml", ".cmt.xml", ".danmu.xml"]
    static let subtitleExtensions = ["ass", "ssa", "srt", "vtt"]

    public static func danmaku(for video: String, in files: [String]) -> String? {
        let base = (video as NSString).deletingPathExtension.lowercased()
        let lowered = Dictionary(files.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // Most specific names first.
        for suffix in danmakuSuffixes.reversed() {
            if let match = lowered[base + suffix] { return match }
        }
        return nil
    }

    /// Subtitle files for a video: "<base>.srt", "<base>.zh.ass", "<base>.chs.srt"…
    public static func subtitles(for video: String, in files: [String]) -> [String] {
        let base = (video as NSString).deletingPathExtension.lowercased()
        return files.filter { f in
            let l = f.lowercased()
            return subtitleExtensions.contains((l as NSString).pathExtension) && (l.hasPrefix(base + ".") || (l as NSString).deletingPathExtension == base)
        }
        .sorted()
    }
}

public enum LocalResume {
    /// Where to start: the saved position unless it's under 5 s or within 10 s of a known end.
    public static func startPosition(saved: Double, length: Double) -> Double? {
        guard saved > 5 else { return nil }
        if length > 0, saved >= length - 10 { return nil }
        return saved
    }

    /// VLC reports `.ended` also after open/read failures: only treat it as completion near the end.
    public static func isCompletion(time: Double, length: Double) -> Bool {
        length > 0 && time >= length - 10
    }
}

/// Turns VLC's coarse media time (~4 updates/s) into a smooth per-frame clock: anchors on each new
/// value and extrapolates with elapsed × rate in between; jumps re-anchor (seeks).
public struct MediaTimeSmoother: Sendable {
    private var anchor: Double?
    private var smoothed: Double = 0
    public var seekThreshold = 1.5

    public init() {}

    public mutating func update(reported: Double, playing: Bool, rate: Double, elapsed: Double) -> Double {
        defer { anchor = reported }
        guard let last = anchor else {
            smoothed = reported
            return smoothed
        }
        if abs(reported - smoothed) > seekThreshold {
            smoothed = reported // seek or long stall: snap
        } else if reported != last {
            // New sample: move towards it without going backwards.
            smoothed = max(smoothed, reported)
        } else if playing {
            // Between samples: extrapolate, but never run more than one sample period ahead.
            smoothed = min(smoothed + elapsed * rate, reported + 0.5)
        }
        return smoothed
    }

    public mutating func reset() {
        anchor = nil
    }
}
