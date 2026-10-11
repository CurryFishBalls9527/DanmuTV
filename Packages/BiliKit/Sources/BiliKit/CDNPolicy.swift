import Foundation

/// CDN strategy: which mirrors to try, in which order.
public struct CDNPolicy: Equatable, Sendable {
    /// MCDN/PCDN last.
    public var preferOfficial = false
    /// Akamai mirrors first (better outside mainland China).
    public var preferAkamai = false
    /// Replace official upos hosts with this one (tried first; originals stay as fallbacks).
    public var rewriteHost: String?
    /// Hosts never to use.
    public var blacklist: Set<String> = []

    public init(preferOfficial: Bool = false, preferAkamai: Bool = false, rewriteHost: String? = nil, blacklist: Set<String> = []) {
        self.preferOfficial = preferOfficial
        self.preferAkamai = preferAkamai
        self.rewriteHost = rewriteHost
        self.blacklist = blacklist
    }

    /// Preset mirrors for 强制替换线路.
    public static let presetHosts: [(name: String, host: String)] = [
        ("腾讯云", "upos-sz-mirrorcos.bilivideo.com"),
        ("阿里云", "upos-sz-mirrorali.bilivideo.com"),
        ("华为云", "upos-sz-mirrorhw.bilivideo.com"),
        ("百度云", "upos-sz-mirrorbd.bilivideo.com"),
        ("Akamai（海外）", "upos-hz-mirrorakam.akamaized.net"),
    ]
}

/// Hosts that failed TLS validation this session (屏蔽证书异常的 CDN).
public final class CDNHealth: @unchecked Sendable {
    public static let shared = CDNHealth()
    private let lock = NSLock()
    private var bad: Set<String> = []

    public func markBad(_ host: String) { lock.withLock { _ = bad.insert(host.lowercased()) } }
    public var badHosts: Set<String> { lock.withLock { bad } }
    public func reset() { lock.withLock { bad = [] } }

    public static func isCertificateError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                .serverCertificateHasUnknownRoot].contains(e.code)
    }

    /// Same check for AVPlayer error-log events (segment fetches never pass through our code).
    public static func isCertificateError(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && (-1206 ... -1200).contains(code) && code != -1200
    }
}

extension CDN {
    public static func isAkamai(_ url: String) -> Bool {
        URLComponents(string: url)?.host?.contains("akamaized.net") == true
    }

    /// Official upos URLs carry their signature in the query, so the host can be swapped.
    static func isRewritable(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let host = c.host else { return false }
        return !isPCDN(url) && (host.hasSuffix(".bilivideo.com") || host.hasSuffix(".akamaized.net")) && host.hasPrefix("upos-")
    }

    public static func ordered(_ urls: [String], policy: CDNPolicy, badHosts: Set<String> = CDNHealth.shared.badHosts) -> [String] {
        let blocked = policy.blacklist.union(badHosts)
        func isBlocked(_ url: String) -> Bool {
            guard let host = URLComponents(string: url)?.host?.lowercased() else { return true }
            return blocked.contains { rule in
                // ".mcdn.bilivideo.cn" / "*.mcdn.bilivideo.cn" block a whole domain (PCDN hosts are per node).
                if rule.hasPrefix("*.") { return host.hasSuffix(String(rule.dropFirst(1))) }
                if rule.hasPrefix(".") { return host.hasSuffix(rule) }
                return host == rule
            }
        }
        var list = urls.filter { !isBlocked($0) }
        if list.isEmpty { list = urls } // never end up with nothing to try
        var rewroteFirst = false
        if let host = policy.rewriteHost?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty,
           let source = list.first(where: isRewritable), var c = URLComponents(string: source)
        {
            c.host = host
            if let rewritten = c.string, !list.contains(rewritten), !isBlocked(rewritten) {
                list.insert(rewritten, at: 0)
                rewroteFirst = true
            }
        }
        if policy.preferAkamai {
            let pinned = rewroteFirst ? Array(list.prefix(1)) : []
            let rest = Array(list.dropFirst(pinned.count))
            list = pinned + rest.filter(isAkamai) + rest.filter { !isAkamai($0) }
        }
        if policy.preferOfficial {
            list = list.filter { !isPCDN($0) } + list.filter(isPCDN)
        }
        return list
    }
}

/// How the TV's output mode follows the content (匹配动态范围和帧率).
public enum DisplayMatchMode: String, CaseIterable, Identifiable, Sendable {
    case off, always, hdrOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "关闭"
        case .always: return "总是匹配"
        case .hdrOnly: return "仅 HDR / 杜比视界时匹配"
        }
    }
}

public struct DisplayPlan: Equatable, Sendable {
    /// Let AVKit set the display criteria from the stream.
    public var automatic: Bool
    /// Set the criteria ourselves with this refresh rate…
    public var manualRefreshRate: Double?
    /// …and this range ("SDR" / "PQ" / "HLG").
    public var manualRange: String

    public static func make(mode: DisplayMatchMode, contentRange: String, contentFrameRate: Double,
                            forcedRefreshRate: Double, forceSDR: Bool) -> DisplayPlan
    {
        let leaveAlone = DisplayPlan(automatic: false, manualRefreshRate: nil, manualRange: "SDR")
        let range = forceSDR ? "SDR" : contentRange
        switch mode {
        case .off:
            return leaveAlone
        case .hdrOnly where range == "SDR":
            // SDR content never switches the TV in this mode, forced rate or not.
            return leaveAlone
        default:
            break
        }
        if forcedRefreshRate > 0 {
            // A fixed output rate (e.g. 59.94 to avoid HDMI re-syncs); range follows the content unless SDR is forced.
            return DisplayPlan(automatic: false, manualRefreshRate: forcedRefreshRate, manualRange: range)
        }
        if forceSDR {
            let rate = standardRate(contentFrameRate)
            return DisplayPlan(automatic: false, manualRefreshRate: rate, manualRange: "SDR")
        }
        return DisplayPlan(automatic: true, manualRefreshRate: nil, manualRange: range)
    }

    /// Snaps odd encoder rates (e.g. 29.412) to the nearest broadcast rate; nil if unknown.
    public static func standardRate(_ fps: Double) -> Double? {
        guard fps > 0 else { return nil }
        let rates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        return rates.min { abs($0 - fps) < abs($1 - fps) }
    }
}

extension API {
    /// Whether the client IP is outside mainland China (used to auto-prefer Akamai).
    public static func isOverseas() async throws -> Bool {
        let d = try await client.get("https://api.bilibili.com/x/web-interface/zone")["data"]
        return d["country"].stringValue != "中国"
    }
}
