import XCTest

/// 投屏 driven the way the official phone app does it: an NVA connection to the app (port 9958 on this
/// simulator), `SETUP /projection`, then command frames. State comes from the player's DEBUG marker.
final class CastTests: RemoteTestCase {
    private static let video = (aid: 117_410_329_855_933, bvid: "BV1vGp46bEdw")
    /// Multi-part: P3 is cid 279787.
    private static let other = (aid: 170_001, bvid: "BV17x411w7KC", p3: 279_787)

    private var marker: XCUIElement { app.descendants(matching: .any)["player.state"] }
    private var phone: FakePhone!

    override func tearDown() {
        phone?.close()
        super.tearDown()
    }

    private func state() -> [String: String] {
        let value = marker.exists ? marker.value as? String ?? "" : ""
        return Dictionary(value.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { $1 })
    }

    @discardableResult
    private func waitFor(_ what: String, timeout: TimeInterval = 25, _ condition: ([String: String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(state()) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("timed out waiting for \(what); state: \(state())")
        return false
    }

    private func connect() {
        launch(settle: 6)
        phone = FakePhone()
        XCTAssertTrue(phone.setup(), "SETUP /projection should be accepted")
    }

    private func cast(_ aid: Int, cid: Int = 0, at seconds: Int) {
        phone.command("Play", ["aid": aid, "cid": cid, "epid": 0, "season_id": 0, "seekTs": seconds, "content_type": 0])
    }

    func testCastPlaysAtThePhonesPositionAndFollowsItsControls() {
        connect()
        phone.command("GetVolume")
        XCTAssertTrue(phone.waitFor(timeout: 3) { $0.kind == 0xC0 && $0.json?["volume"] != nil }, "GetVolume is answered with a volume")
        cast(Self.video.aid, at: 40)
        XCTAssertTrue(phone.waitFor(timeout: 3) { $0.kind == 0xC0 && $0.json == nil }, "Play is acknowledged")
        waitFor("playing the cast video") { $0["bvid"] == Self.video.bvid && $0["status"] == "playing" }
        XCTAssertTrue(phone.waitFor(timeout: 5) { $0.name == "OnPlayState" && $0.json?["playState"] as? Int == 4 }, "the phone hears 'playing'")
        XCTAssertTrue(phone.waitFor(timeout: 5) { $0.name == "OnProgress" && ($0.json?["position"] as? Int ?? 0) >= 40 }, "and the position")
        let start = Int(state()["pos"] ?? "") ?? 0
        log("started at \(start)s")
        XCTAssertTrue((40 ... 46).contains(start), "should start where the phone was (40 s), not from history")
        shot("cast-playing")

        phone.command("Pause")
        waitFor("paused", timeout: 5) { $0["status"] == "paused" }
        XCTAssertTrue(phone.waitFor(timeout: 5) { $0.name == "OnPlayState" && $0.json?["playState"] as? Int == 5 }, "the phone hears 'paused'")
        phone.command("Seek", ["seekTs": 70])
        phone.command("SwitchSpeed", ["speed": "1.5"])
        phone.command("Resume")
        waitFor("resumed at 1.5× after the seek", timeout: 8) {
            $0["status"] == "playing" && $0["rate"] == "1.5" && (Int($0["pos"] ?? "") ?? 0) >= 70
        }

        phone.command("Stop")
        XCTAssertTrue(phone.waitFor(timeout: 5) { $0.name == "OnPlayState" && $0.json?["playState"] as? Int == 7 }, "the phone hears 'stopped'")
        let gone = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker)], timeout: 8)
        XCTAssertEqual(gone, .completed, "Stop closes the player")
        shot("cast-stopped")
    }

    /// The phone sends Play again for what's already on (e.g. after reconnecting): no reload, just the position.
    func testRecastingTheSameVideoOnlySeeks() {
        connect()
        cast(Self.video.aid, at: 10)
        waitFor("playing") { $0["bvid"] == Self.video.bvid && $0["status"] == "playing" }
        let instance = state()["id"]
        cast(Self.video.aid, at: 60)
        waitFor("moved to 60 s", timeout: 8) { (Int($0["pos"] ?? "") ?? 0) >= 60 }
        XCTAssertEqual(state()["id"], instance, "the same player instance (no reload)")
        XCTAssertEqual(state()["bvid"], Self.video.bvid)
    }

    func testCastPicksThePartThePhoneIsOn() {
        connect()
        cast(Self.other.aid, cid: Self.other.p3, at: 30)
        waitFor("P3 of the multi-part video") { $0["cid"] == "\(Self.other.p3)" && $0["status"] == "playing" }
        XCTAssertTrue((30 ... 36).contains(Int(state()["pos"] ?? "") ?? 0), "at the phone's position: \(state())")
    }

    /// Replacing the video shows the phone loading → playing, never 'stopped' (which ends its remote UI).
    func testReplacingIsNotReportedAsStopped() {
        connect()
        cast(Self.video.aid, at: 5)
        waitFor("first") { $0["bvid"] == Self.video.bvid && $0["status"] == "playing" }
        phone.clear()
        cast(Self.other.aid, at: 5)
        waitFor("second") { $0["bvid"] == Self.other.bvid && $0["status"] == "playing" }
        XCTAssertTrue(phone.waitFor(timeout: 5) { $0.name == "OnPlayState" && $0.json?["playState"] as? Int == 4 })
        XCTAssertFalse(phone.received.contains { $0.name == "OnPlayState" && $0.json?["playState"] as? Int == 7 },
                       "states: \(phone.received.filter { $0.name == "OnPlayState" }.map { $0.json ?? [:] })")
    }

    func testCastReplacesTheVideoOnScreen() {
        connect()
        cast(Self.other.aid, at: 5)
        waitFor("first video") { $0["bvid"] == Self.other.bvid && $0["status"] == "playing" }
        cast(Self.video.aid, at: 20)
        waitFor("replaced by the second") { $0["bvid"] == Self.video.bvid && $0["status"] == "playing" }
        shot("cast-replaced")
    }
}

/// The same phone, speaking UPnP SOAP the way current official apps do.
final class CastSOAPTests: RemoteTestCase {
    private var marker: XCUIElement { app.descendants(matching: .any)["player.state"] }

    private func state() -> [String: String] {
        let value = marker.exists ? marker.value as? String ?? "" : ""
        return Dictionary(value.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { $1 })
    }

    @discardableResult
    private func waitFor(_ what: String, timeout: TimeInterval = 25, _ condition: ([String: String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(state()) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("timed out waiting for \(what); state: \(state())")
        return false
    }

    /// SetAVTransportURI shaped like the official app's: the identity (a synthetic one, for the test video) is encrypted
    /// in the DIDL longDescription.
    private static let officialSetURI = """
    <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>\
    <CurrentURI>bilibili://projection?proj_source=bilibili&amp;_nva_ext_=</CurrentURI>\
    <CurrentURIMetaData>&lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;&lt;item id="0" parentID="-1" restricted="1"&gt;&lt;dc:title&gt;测试视频&lt;/dc:title&gt;&lt;upnp:longDescription&gt;LIMmQLRJ5m-eajAT_LGUZhY1E5bKuVUq2iPxS3SzCjRbfaWqTRI7LfuzCPJFkpopnpf0OD8eiYe5qf66nGetX4G6SjEWUqhDcHrsIP-6xaQjS0S2DQGxVnOJupVrUb5Wgq7WVFFKNu3iu82Q8XRtW0Tlj6VLRGRPWZjLoEsA09rK8tma0wDZLy_YYBL6N15G0Rj2Ic9Z1XLUGk3m1N-n8A&lt;/upnp:longDescription&gt;&lt;upnp:class&gt;object.item.videoItem&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>\
    </u:SetAVTransportURI></s:Body></s:Envelope>
    """

    private func soap(_ service: String, _ action: String, _ body: String = "") -> String {
        let urn = service == "NirvanaControl" ? "urn:app-bilibili-com:service:NirvanaControl:3" : "urn:schemas-upnp-org:service:\(service):1"
        let envelope = body.isEmpty
            ? "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action) xmlns:u=\"\(urn)\"><InstanceID>0</InstanceID></u:\(action)></s:Body></s:Envelope>"
            : body
        return HTTP.request("POST", "/\(service)/action", headers: ["SOAPAction": "\"\(urn)#\(action)\"", "Content-Type": "text/xml"], body: envelope)
    }

    func testOfficialAppCastOverSOAP() {
        launch(settle: 6)
        let description = HTTP.request("GET", "/description.xml")
        XCTAssertTrue(description.contains("NirvanaControl:3") && description.contains("RenderingControl:1"), "device description")
        XCTAssertTrue(HTTP.request("GET", "/dlna/NirvanaControl.xml").contains("<name>GetPlayInfo</name>"))
        XCTAssertTrue(soap("NirvanaControl", "GetAppInfo").contains("<PackageName>com.xiaodianshi.tv.yst</PackageName>"))

        XCTAssertTrue(soap("AVTransport", "SetAVTransportURI", Self.officialSetURI).contains("SetAVTransportURIResponse"))
        _ = soap("AVTransport", "Play")
        waitFor("the decoded video playing") { $0["cid"] == "42594076299" && $0["status"] == "playing" }
        shot("cast-soap-playing")

        let info = soap("NirvanaControl", "GetPlayInfo")
        XCTAssertTrue(info.contains("42594076299") && info.contains("playerStatus"), "GetPlayInfo reports the video: \(info.prefix(300))")
        _ = soap("AVTransport", "Pause")
        waitFor("paused", timeout: 5) { $0["status"] == "paused" }
        XCTAssertTrue(soap("AVTransport", "GetTransportInfo").contains("PAUSED_PLAYBACK"))
        _ = soap("AVTransport", "Seek", "<s:Envelope><s:Body><u:Seek xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>00:00:20</Target></u:Seek></s:Body></s:Envelope>")
        waitFor("moved to 20 s", timeout: 6) { (Int($0["pos"] ?? "") ?? 0) >= 19 }
        let position = soap("AVTransport", "GetPositionInfo")
        XCTAssertTrue(position.contains("<RelTime>00:00:2") || position.contains("<RelTime>00:00:19"), "position reported: \(position.suffix(400))")
        _ = soap("AVTransport", "Stop")
        let gone = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker)], timeout: 8)
        XCTAssertEqual(gone, .completed, "Stop closes the player")
    }
}

/// One HTTP request to the app's cast port over a raw socket (no ATS), returning the whole response.
private enum HTTP {
    static func request(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9958).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return "" }
        let bodyData = Data(body.utf8)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:9958\r\nConnection: close\r\nContent-Length: \(bodyData.count)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        let request = Data((head + "\r\n").utf8) + bodyData
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, request.count, 0) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0 ..< n])
        }
        return String(decoding: response, as: UTF8.self)
    }
}

/// Minimal NVA client (the phone's side), on blocking sockets; frames from the TV are collected in `received`.
private final class FakePhone {
    struct Frame {
        var kind: UInt8
        var name: String?
        var json: [String: Any]?
    }

    private var fd: Int32 = -1
    private var seq: UInt32 = 0
    private let lock = NSLock()
    private var frames: [Frame] = []

    var received: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func clear() {
        lock.lock()
        frames = []
        lock.unlock()
    }

    func waitFor(timeout: TimeInterval, _ match: (Frame) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if received.contains(where: match) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func readExact(_ count: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: max(count, 1))
        while data.count < count {
            let n = read(fd, &chunk, count - data.count)
            if n <= 0 {
                if n < 0, errno == EAGAIN, fd >= 0 { continue }
                return nil
            }
            data.append(contentsOf: chunk[0 ..< n])
        }
        return data
    }

    private func readLoop() {
        func u32(_ d: Data) -> Int { d.reduce(0) { $0 << 8 | Int($1) } }
        while fd >= 0, let header = readExact(6) {
            let kind = header[0], count = Int(header[1])
            var frame = Frame(kind: kind)
            if kind == 0xE0 {
                guard readExact(1) != nil, let cl = readExact(1), readExact(Int(cl[0])) != nil,
                      let nl = readExact(1), let name = readExact(Int(nl[0])) else { return }
                frame.name = String(data: name, encoding: .utf8)
            }
            if (kind == 0xE0 && count == 3) || (kind == 0xC0 && count == 1) {
                guard let lengthBytes = readExact(4), let body = readExact(u32(lengthBytes)) else { return }
                frame.json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }
    }

    init() {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9958).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 { close() }
    }

    func setup() -> Bool {
        guard fd >= 0 else { return false }
        write(Data("SETUP /projection NVA/1.0\r\nSession: ui-test\r\nNvaVersion: 1\r\nConnection: Keep-Alive\r\n\r\n".utf8))
        var head = Data()
        var byte: UInt8 = 0
        while !head.suffix(4).elementsEqual("\r\n\r\n".utf8), read(fd, &byte, 1) == 1 { head.append(byte) }
        guard String(data: head, encoding: .utf8)?.hasPrefix("NVA/1.0 200 OK") == true else { return false }
        Thread { [self] in readLoop() }.start()
        return true
    }

    func command(_ name: String, _ body: [String: Any]? = nil) {
        seq += 1
        let json = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        var frame = Data([0xE0, json == nil ? 2 : 3])
        frame.append(contentsOf: withUnsafeBytes(of: seq.bigEndian, Array.init))
        frame.append(0x01)
        frame.append(7)
        frame.append(Data("Command".utf8))
        frame.append(UInt8(name.utf8.count))
        frame.append(Data(name.utf8))
        if let json {
            frame.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init))
            frame.append(json)
        }
        write(frame)
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func write(_ data: Data) {
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
