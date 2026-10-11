import Foundation

/// 投屏: the official app's 云视听小电视 cast protocol ("哔哩必连" / NVA). The TV announces itself over SSDP as a
/// DLNA MediaRenderer with Bilibili's NirvanaControl service; the phone then opens a TCP connection with
/// `SETUP /projection NVA/1.0` and exchanges binary frames on it (commands from the phone, playback events back).
public enum NVA {
    public static let port: UInt16 = 9958

    public enum Frame: Equatable, Sendable {
        /// 0xE0: `Command` + name, optionally with a JSON body.
        case command(seq: UInt32, name: String, body: Data?)
        /// 0xC0: answer to a command, optionally with a JSON body.
        case reply(seq: UInt32, body: Data?)
        /// 0xE4: keep-alive.
        case ping(seq: UInt32)
    }

    public enum DecodeError: Error, Equatable {
        case unknownType(UInt8)
        case badParameterCount(UInt8)
        case badText
        case tooLarge(Int)
    }

    /// Real bodies are a few hundred bytes; anything this big is garbage (or hostile) and closes the connection.
    public static let maxBodyLength = 256 * 1024

    /// Splits the byte stream into frames; bytes of an incomplete frame stay buffered until the rest arrives.
    ///
    /// Layout (big-endian): type, parameter count, 4-byte sequence number. Commands then carry a version byte and
    /// their parameters: the first two with a 1-byte length (`"Command"`, the name), a third (JSON) with a 4-byte
    /// length. A reply's single parameter (JSON) has a 4-byte length.
    public struct Decoder {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) {
            buffer.append(data)
        }

        public mutating func next() throws -> Frame? {
            var reader = Reader(data: buffer)
            guard let type = reader.byte(), let count = reader.byte(), let seq = reader.uint32() else { return nil }
            let frame: Frame
            switch type {
            case 0xE4:
                frame = .ping(seq: seq)
            case 0xC0:
                guard count <= 1 else { throw DecodeError.badParameterCount(count) }
                var body: Data?
                if count == 1 {
                    guard let length = reader.uint32() else { return nil }
                    guard Int(length) <= NVA.maxBodyLength else { throw DecodeError.tooLarge(Int(length)) }
                    guard let bytes = reader.bytes(Int(length)) else { return nil }
                    body = bytes
                }
                frame = .reply(seq: seq, body: body)
            case 0xE0:
                guard (2 ... 3).contains(count) else { throw DecodeError.badParameterCount(count) }
                guard reader.byte() != nil, // version
                      let commandLength = reader.byte(), reader.bytes(Int(commandLength)) != nil,
                      let nameLength = reader.byte(), let name = reader.bytes(Int(nameLength))
                else { return nil }
                var body: Data?
                if count == 3 {
                    guard let length = reader.uint32() else { return nil }
                    guard Int(length) <= NVA.maxBodyLength else { throw DecodeError.tooLarge(Int(length)) }
                    guard let bytes = reader.bytes(Int(length)) else { return nil }
                    body = bytes
                }
                guard let text = String(bytes: name, encoding: .utf8) else { throw DecodeError.badText }
                frame = .command(seq: seq, name: text, body: body)
            default:
                throw DecodeError.unknownType(type)
            }
            buffer.removeFirst(reader.offset)
            if buffer.isEmpty { buffer = Data() } // drop the consumed storage
            return frame
        }
    }

    public static func encode(_ frame: Frame) -> Data {
        var out = Data()
        func uint32(_ value: UInt32) { out.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
        switch frame {
        case let .ping(seq):
            out.append(contentsOf: [0xE4, 0x00])
            uint32(seq)
        case let .reply(seq, body):
            out.append(contentsOf: [0xC0, body == nil ? 0 : 1])
            uint32(seq)
            if let body {
                uint32(UInt32(body.count))
                out.append(body)
            }
        case let .command(seq, name, body):
            let command = Data("Command".utf8), nameData = Data(name.utf8)
            out.append(contentsOf: [0xE0, body == nil ? 2 : 3])
            uint32(seq)
            out.append(0x01)
            out.append(UInt8(command.count))
            out.append(command)
            out.append(UInt8(nameData.count))
            out.append(nameData)
            if let body {
                uint32(UInt32(body.count))
                out.append(body)
            }
        }
        return out
    }

    /// `OnPlayState` values.
    public enum PlayState: Int, Sendable {
        case loading = 3, playing = 4, paused = 5, ended = 6, stopped = 7
    }

    /// Reads `data` in place (no copy per attempt); `offset` counts bytes consumed.
    private struct Reader {
        let data: Data
        var offset = 0

        mutating func byte() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, count <= data.count - offset else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return data.subdata(in: start ..< start + count)
        }

        mutating func uint32() -> UInt32? {
            bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }
    }
}

/// What the phone asked the TV to play.
public struct CastRequest: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case video(aid: Int, cid: Int)
        case episode(epID: Int, seasonID: Int)
        case live(roomID: Int)
    }

    public var content: Content
    /// Where the phone was (seconds).
    public var startAt: Double

    public init(content: Content, startAt: Double = 0) {
        self.content = content
        self.startAt = startAt
    }

    /// `Play` carries the fields directly; iOS's `PlayUrl` wraps them in the `nva_ext` query item of a URL.
    public static func parse(command: String, body: Data?) -> CastRequest? {
        guard let body, let json = try? JSON(data: body) else { return nil }
        switch command {
        case "Play":
            return parse(json)
        case "PlayUrl":
            guard let url = URLComponents(string: json["url"].stringValue),
                  let ext = url.queryItems?.first(where: { $0.name == "nva_ext" })?.value,
                  let extJSON = try? JSON(data: Data(ext.utf8))
            else { return nil }
            return parse(extJSON["content"])
        default:
            return nil
        }
    }

    /// Field names vary by client version: `seekTs` / `sk`, `epid` / `epId` / `eid`, `season_id` / `seasonId` / `sid`.
    static func parse(_ json: JSON) -> CastRequest? {
        func first(_ keys: String...) -> Int { keys.lazy.compactMap { json[$0].int }.first { $0 > 0 } ?? 0 }
        let startAt = max(0, json["seekTs"].double ?? json["sk"].double ?? 0)
        let roomID = first("roomId", "room_id")
        if roomID > 0 {
            return CastRequest(content: .live(roomID: roomID))
        }
        let epID = first("epid", "epId", "ep_id", "eid")
        if epID > 0 {
            return CastRequest(content: .episode(epID: epID, seasonID: first("season_id", "seasonId", "sid")), startAt: startAt)
        }
        let aid = json["aid"].intValue
        guard aid > 0 else { return nil }
        return CastRequest(content: .video(aid: aid, cid: json["cid"].intValue), startAt: startAt)
    }
}

/// SSDP messages and the UPnP description that make the official app list the TV as a 小电视.
/// Identifiers the official phone app checks before it sends a video's identity. They are protocol interoperability
/// values, not a claim of origin: the device is always listed as "Danmu TV · …" (friendlyName / modelName), and DanmuTV
/// is not affiliated with Bilibili.
public enum CastInterop {
    /// UPnP `manufacturer` of Bilibili TV receivers.
    public static let manufacturer = "Bilibili Inc."
    public static let manufacturerURL = "https://www.bilibili.com/"
    /// NirvanaControl GetAppInfo `PackageName`: the official TV app's package.
    public static let packageName = "com.xiaodianshi.tv.yst"
}

public enum CastDiscovery {
    public static let multicastHost = "239.255.255.250"
    public static let multicastPort: UInt16 = 1900
    public static let server = "Linux/3.0.0 UPnP/1.0 Platinum/1.0.5.13"

    public static let deviceType = "urn:schemas-upnp-org:device:MediaRenderer:1"
    public static let nirvanaService = "urn:app-bilibili-com:service:NirvanaControl:3"
    public static let transportService = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let renderingService = "urn:schemas-upnp-org:service:RenderingControl:1"
    public static let connectionService = "urn:schemas-upnp-org:service:ConnectionManager:1"
    /// Announced (and answered to searches) in this order.
    public static let targets = ["upnp:rootdevice", deviceType, transportService, renderingService, connectionService, nirvanaService]

    /// A device id (a standard UUID, as current receivers use).
    public static func makeDeviceID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Each service's type, path name (`/dlna/<name>.xml`, `/<name>/action`) and service id.
    public static let services: [(type: String, name: String, id: String)] = [
        (transportService, "AVTransport", "urn:upnp-org:serviceId:AVTransport"),
        (renderingService, "RenderingControl", "urn:upnp-org:serviceId:RenderingControl"),
        (connectionService, "ConnectionManager", "urn:upnp-org:serviceId:ConnectionManager"),
        (nirvanaService, "NirvanaControl", "urn:app-bilibili-com:serviceId:NirvanaControl"),
    ]

    static func usn(_ uuid: String, target: String) -> String {
        target == "uuid:\(uuid)" ? target : "uuid:\(uuid)::\(target)"
    }

    /// The targets a search (`ST`) should be answered with; empty when it isn't for us.
    public static func answers(toSearch message: String) -> [String] {
        let lines = message.components(separatedBy: "\r\n")
        guard lines.first?.uppercased().hasPrefix("M-SEARCH") == true,
              let st = header("ST", in: lines)
        else { return [] }
        if st == "ssdp:all" { return targets }
        return targets.filter { $0.caseInsensitiveCompare(st) == .orderedSame }
    }

    public static func searchResponse(target: String, uuid: String, location: String, date: Date = Date()) -> String {
        lines([
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "DATE: \(httpDate(date))",
            "EXT:",
            "LOCATION: \(location)",
            "SERVER: \(server)",
            "ST: \(target)",
            "USN: \(usn(uuid, target: target))",
        ])
    }

    public static func notify(target: String, uuid: String, location: String, alive: Bool = true) -> String {
        lines([
            "NOTIFY * HTTP/1.1",
            "HOST: \(multicastHost):\(multicastPort)",
            "CACHE-CONTROL: max-age=1800",
            "LOCATION: \(location)",
            "NT: \(target)",
            "NTS: \(alive ? "ssdp:alive" : "ssdp:byebye")",
            "SERVER: \(server)",
            "USN: \(usn(uuid, target: target))",
        ])
    }

    /// The device description: a MediaRenderer (with the `CastInterop` manufacturer) with the three standard services and
    /// NirvanaControl, which together make the official app send `bilibili://projection` with the video's identity.
    public static func description(uuid: String, name: String) -> String {
        let list = services.map { s in
            "<service><serviceType>\(s.type)</serviceType><serviceId>\(s.id)</serviceId>"
                + "<SCPDURL>/dlna/\(s.name).xml</SCPDURL><controlURL>/\(s.name)/action</controlURL>"
                + "<eventSubURL>/\(s.name)/event</eventSubURL></service>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
        <specVersion><major>1</major><minor>0</minor></specVersion>
        <device>
        <deviceType>\(deviceType)</deviceType>
        <friendlyName>\(xmlEscaped(name))</friendlyName>
        <manufacturer>\(CastInterop.manufacturer)</manufacturer>
        <manufacturerURL>\(CastInterop.manufacturerURL)</manufacturerURL>
        <modelDescription>DanmuTV projection receiver</modelDescription>
        <modelName>DanmuTV</modelName>
        <modelNumber>1</modelNumber>
        <UDN>uuid:\(uuid)</UDN>
        <serviceList>\(list)</serviceList>
        </device>
        </root>
        """
    }

    /// Accepted media types (ConnectionManager GetProtocolInfo).
    public static let sinkProtocolInfo = [
        "http-get:*:*:*", "http-get:*:video/mp4:*", "http-get:*:video/x-flv:*", "http-get:*:video/x-matroska:*",
        "http-get:*:video/quicktime:*", "http-get:*:application/vnd.apple.mpegurl:*", "http-get:*:application/x-mpegURL:*",
        "http-get:*:audio/mpeg:*", "http-get:*:audio/mp4:*",
    ].joined(separator: ",")

    /// Service descriptions with argument lists (NirvanaControl's is what marks a Bilibili receiver).
    public static func serviceDescription(named name: String) -> String? {
        typealias Action = (name: String, inputs: [String], outputs: [String])
        let actions: [Action]
        switch name {
        case "AVTransport":
            actions = [
                ("SetAVTransportURI", ["InstanceID", "CurrentURI", "CurrentURIMetaData"], []),
                ("Play", ["InstanceID", "Speed"], []), ("Pause", ["InstanceID"], []), ("Stop", ["InstanceID"], []),
                ("Seek", ["InstanceID", "Unit", "Target"], []),
                ("GetTransportInfo", ["InstanceID"], ["CurrentTransportState", "CurrentTransportStatus", "CurrentSpeed"]),
                ("GetPositionInfo", ["InstanceID"], ["Track", "TrackDuration", "TrackMetaData", "TrackURI", "RelTime", "AbsTime", "RelCount", "AbsCount"]),
                ("GetMediaInfo", ["InstanceID"], ["NrTracks", "MediaDuration", "CurrentURI", "CurrentURIMetaData", "NextURI", "NextURIMetaData", "PlayMedium", "RecordMedium", "WriteStatus"]),
                ("GetCurrentTransportActions", ["InstanceID"], ["Actions"]),
                ("GetDeviceCapabilities", ["InstanceID"], ["PlayMedia", "RecMedia", "RecQualityModes"]),
                ("GetTransportSettings", ["InstanceID"], ["PlayMode", "RecQualityMode"]),
            ]
        case "RenderingControl":
            actions = [
                ("GetMute", ["InstanceID", "Channel"], ["CurrentMute"]), ("SetMute", ["InstanceID", "Channel", "DesiredMute"], []),
                ("GetVolume", ["InstanceID", "Channel"], ["CurrentVolume"]), ("SetVolume", ["InstanceID", "Channel", "DesiredVolume"], []),
            ]
        case "ConnectionManager":
            actions = [
                ("GetProtocolInfo", [], ["Source", "Sink"]),
                ("GetCurrentConnectionIDs", [], ["ConnectionIDs"]),
                ("GetCurrentConnectionInfo", ["ConnectionID"], ["RcsID", "AVTransportID", "ProtocolInfo", "PeerConnectionManager", "PeerConnectionID", "Direction", "Status"]),
            ]
        case "NirvanaControl":
            actions = [
                ("GetAppInfo", [], ["PackageName", "AppKey", "Signature", "CurrentSignedIn"]),
                ("SetDanmakuSwitch", ["DesiredSwitch"], []),
                ("GetPlayInfo", ["Params"], ["Content"]),
                ("GetAccountInfo", [], ["VipInfo"]),
                ("SwitchQuality", ["Qn"], []),
                ("Play", [], []), ("Pause", [], []), ("Stop", [], []), ("Seek", ["Target"], []), ("SetSpeed", ["Speed"], []),
            ]
        default:
            return nil
        }
        func argument(_ name: String, _ direction: String) -> String {
            "<argument><name>\(name)</name><direction>\(direction)</direction><relatedStateVariable>A_ARG_TYPE_String</relatedStateVariable></argument>"
        }
        let list = actions.map { a in
            "<action><name>\(a.name)</name><argumentList>"
                + a.inputs.map { argument($0, "in") }.joined() + a.outputs.map { argument($0, "out") }.joined()
                + "</argumentList></action>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>\
        <actionList>\(list)</actionList><serviceStateTable>\
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_String</name><dataType>string</dataType></stateVariable>\
        </serviceStateTable></scpd>
        """
    }

    static func header(_ name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func lines(_ items: [String]) -> String {
        items.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

/// The text part of the cast connection: plain HTTP for the descriptions, and the `SETUP` that turns the
/// connection into an NVA frame stream.
public struct CastHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public struct Malformed: Error, Equatable {}

    /// Largest head or body accepted; phones send a few hundred bytes.
    public static let maxLength = 64 * 1024

    /// Parses one request from the start of `data`; nil while the head (or the body by Content-Length) is incomplete.
    /// Returns the request and how many bytes it used. Throws on a request that can't be valid (bad or oversized
    /// Content-Length, oversized head): the connection should be closed.
    public static func parse(_ data: Data) throws -> (request: CastHTTPRequest, length: Int)? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxLength { throw Malformed() }
            return nil
        }
        guard end.lowerBound - data.startIndex <= maxLength,
              let head = String(data: data[data.startIndex ..< end.lowerBound], encoding: .utf8)
        else { throw Malformed() }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { throw Malformed() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var bodyLength = 0
        if let value = headers["content-length"] {
            guard let length = Int(value), (0 ... maxLength).contains(length) else { throw Malformed() }
            bodyLength = length
        }
        let headLength = end.upperBound - data.startIndex
        guard data.count >= headLength + bodyLength else { return nil }
        let bodyStart = data.startIndex + headLength
        return (CastHTTPRequest(method: parts[0].uppercased(), path: parts[1], headers: headers,
                                body: Data(data[bodyStart ..< bodyStart + bodyLength])),
                headLength + bodyLength)
    }
}
