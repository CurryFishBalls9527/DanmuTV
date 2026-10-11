import CommonCrypto
import Foundation

/// 投屏 over standard UPnP (what current official apps use): SOAP actions on AVTransport / RenderingControl /
/// ConnectionManager plus Bilibili's NirvanaControl. When the phone recognises a Bilibili receiver, SetAVTransportURI
/// carries `bilibili://projection` and the video's identity in an encrypted `_nva_ext_` (in the URI or the DIDL
/// `longDescription`); other senders give a plain media URL. Protocol details follow NeoBV's receiver (MIT).
public enum SOAP {
    /// `"urn:…:AVTransport:1#Play"` → ("urn:…:AVTransport:1", "Play").
    public static func action(header: String?) -> (service: String, name: String)? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let hash = value.lastIndex(of: "#") else { return nil }
        return (String(value[..<hash]), String(value[value.index(after: hash)...]))
    }

    /// Text of the first `<name>` / `<x:name>` element in `xml` (entities not decoded).
    public static func element(_ name: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_.-]+:)?\(NSRegularExpression.escapedPattern(for: name))\\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?\(NSRegularExpression.escapedPattern(for: name))>",
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
            let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        return String(xml[range])
    }

    public static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func response(service: String, action: String, values: [(String, String)] = []) -> String {
        let body = values.map { "<\($0)>\(escape($1))</\($0)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action)Response xmlns:u="\(service)">\(body)</u:\(action)Response></s:Body></s:Envelope>
        """
    }

    /// "01:02:03" / "1:02:03.500" → seconds.
    public static func seconds(fromTime text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// Seconds → "hh:mm:ss".
    public static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// What a SetAVTransportURI asked for.
public struct DLNAContent: Equatable, Sendable {
    /// The Bilibili video / episode / room, when the phone sent its identity.
    public var request: CastRequest?
    /// A plain media URL (other apps, or no identity).
    public var mediaURL: URL?
    public var title: String
}

extension DLNAContent {
    /// Reads the SetAVTransportURI body: `_nva_ext_` from the URI query or the DIDL longDescription, else ids in
    /// the query, else the media URL.
    public static func parse(setURIBody body: String) -> DLNAContent? {
        let uri = SOAP.element("CurrentURI", in: body).map { SOAP.unescape($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let didl = SOAP.element("CurrentURIMetaData", in: body).map { SOAP.unescape(SOAP.unescape($0)) } ?? ""
        let title = SOAP.element("title", in: didl).map(SOAP.unescape) ?? ""

        var candidates: [JSON] = []
        let query = URLComponents(string: uri)?.queryItems ?? []
        for name in ["_nva_ext_", "nva_ext"] {
            if let value = query.first(where: { $0.name == name })?.value, let json = NvaExt.decode(value) { candidates.append(json) }
        }
        if let long = SOAP.element("longDescription", in: didl).map(SOAP.unescape), let json = NvaExt.decode(long) {
            candidates.append(json)
        }
        var fields: [String: Any] = [:]
        for item in query { if let value = item.value { fields[item.name] = value } }
        candidates.append(JSON(fields))

        for json in candidates {
            if let request = CastRequest.parse(json["content"].exists ? json["content"] : json) {
                return DLNAContent(request: request, mediaURL: nil, title: title)
            }
        }
        if let url = URL(string: uri), url.scheme == "http" || url.scheme == "https" {
            return DLNAContent(request: nil, mediaURL: url, title: title)
        }
        return nil
    }
}

/// `_nva_ext_`: AES-128-CBC (key = IV = a fixed string) over raw-deflated JSON, base64url-encoded; older clients
/// send it hex-encoded and not deflated, or as plain JSON.
public enum NvaExt {
    private static let key = Array("1pzhA828t4i.6Oq@".utf8)

    public static func decode(_ value: String) -> JSON? {
        let text = (value.removingPercentEncoding ?? value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return try? JSON(data: Data(text.utf8)) }
        for encrypted in [base64URL(text), hex(text)].compactMap({ $0 }) {
            guard let plain = decrypt(encrypted) else { continue }
            for candidate in [try? (plain as NSData).decompressed(using: .zlib) as Data, plain] {
                if let candidate, candidate.first == UInt8(ascii: "{"), let json = try? JSON(data: candidate) { return json }
            }
        }
        return nil
    }

    static func base64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.filter { !$0.isWhitespace }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func decrypt(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var written = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, key, inBytes.baseAddress, data.count, outBytes.baseAddress, outCapacity, &written)
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }
}

/// What the receiver reports back (GetPlayInfo / GetPositionInfo / OnProgress).
public struct CastStatus: Sendable {
    public var state: NVA.PlayState
    public var position: Double
    public var duration: Double
    public var speed: Double
    public var danmaku: Bool
    public var aid: Int
    public var cid: Int
    public var epID: Int
    public var seasonID: Int
    public var title: String

    public init(state: NVA.PlayState, position: Double = 0, duration: Double = 0, speed: Double = 1, danmaku: Bool = true,
                aid: Int = 0, cid: Int = 0, epID: Int = 0, seasonID: Int = 0, title: String = "")
    {
        self.state = state
        self.position = position
        self.duration = duration
        self.speed = speed
        self.danmaku = danmaku
        self.aid = aid
        self.cid = cid
        self.epID = epID
        self.seasonID = seasonID
        self.title = title
    }

    public static let stopped = CastStatus(state: .stopped)

    /// UPnP transport state.
    public var transportState: String {
        switch state {
        case .playing: return "PLAYING"
        case .paused: return "PAUSED_PLAYBACK"
        case .loading: return "TRANSITIONING"
        case .ended, .stopped: return "STOPPED"
        }
    }

    /// NirvanaControl GetPlayInfo `Content`.
    public var playInfoJSON: String {
        let speedText = speed.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(speed)) : String(speed)
        let object: [String: Any] = [
            "aid": aid > 0 ? String(aid) : "", "cid": cid > 0 ? String(cid) : "",
            "epId": epID > 0 ? String(epID) : "", "seasonId": seasonID > 0 ? String(seasonID) : "", "roomId": "",
            "duration": Int(max(0, duration) * 1000), "position": Int(max(0, position)),
            "playerStatus": state.rawValue, "playState": state.rawValue,
            "danmakuStatus": danmaku ? 1 : 0, "danmakuState": danmaku,
            "supportVideoDanmaku": true, "supportLiveDanmaku": true, "supportMultiSpeed": true, "isLastEp": false,
            "playItem": ["aid": aid, "cid": cid, "epId": epID, "seasonId": seasonID, "roomId": 0, "contentType": 0],
            "title": title, "volume": 100,
            "speedInfo": ["supportSpeedList": [0.5, 0.75, 1.0, 1.25, 1.5, 2.0], "currSpeed": Double(speedText) ?? 1],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
