@testable import BiliKit
import XCTest

final class CastTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Frames

    func testCommandLayout() {
        let body = Data(#"{"seekTs":12}"#.utf8)
        let bytes = [UInt8](NVA.encode(.command(seq: 2, name: "Seek", body: body)))
        XCTAssertEqual(Array(bytes[0 ..< 7]), [0xE0, 0x03, 0, 0, 0, 2, 0x01])
        XCTAssertEqual(bytes[7], 7)
        XCTAssertEqual(String(bytes: bytes[8 ..< 15], encoding: .utf8), "Command")
        XCTAssertEqual(bytes[15], 4)
        XCTAssertEqual(String(bytes: bytes[16 ..< 20], encoding: .utf8), "Seek")
        XCTAssertEqual(Array(bytes[20 ..< 24]), [0, 0, 0, UInt8(body.count)])
        XCTAssertEqual(Data(bytes[24...]), body)
    }

    func testReplyAndPingLayout() {
        XCTAssertEqual([UInt8](NVA.encode(.reply(seq: 1, body: nil))), [0xC0, 0, 0, 0, 0, 1])
        XCTAssertEqual([UInt8](NVA.encode(.ping(seq: 0x0102_0304))), [0xE4, 0, 1, 2, 3, 4])
        let reply = [UInt8](NVA.encode(.reply(seq: 3, body: Data("{}".utf8))))
        XCTAssertEqual(reply, [0xC0, 1, 0, 0, 0, 3, 0, 0, 0, 2, 0x7B, 0x7D])
    }

    func testRoundTrip() throws {
        let frames: [NVA.Frame] = [
            .command(seq: 1, name: "GetVolume", body: nil),
            .command(seq: 2, name: "Play", body: json(["aid": 1, "cid": 2])),
            .reply(seq: 3, body: json(["volume": 30])),
            .reply(seq: 4, body: nil),
            .ping(seq: 5),
        ]
        var decoder = NVA.Decoder()
        decoder.append(frames.map(NVA.encode).reduce(Data(), +))
        var decoded: [NVA.Frame] = []
        while let frame = try decoder.next() { decoded.append(frame) }
        XCTAssertEqual(decoded, frames)
    }

    func testPartialFramesWaitForTheRest() throws {
        let data = NVA.encode(.command(seq: 9, name: "Play", body: json(["aid": 170_001])))
        var decoder = NVA.Decoder()
        for byte in data.dropLast() {
            decoder.append(Data([byte]))
            XCTAssertNil(try decoder.next())
        }
        decoder.append(Data([data.last!]))
        guard case let .command(seq, name, body) = try decoder.next() else { return XCTFail("no frame") }
        XCTAssertEqual(seq, 9)
        XCTAssertEqual(name, "Play")
        XCTAssertEqual(try JSON(data: body!)["aid"].intValue, 170_001)
        XCTAssertNil(try decoder.next())
    }

    func testUnknownTypeIsAnError() {
        var decoder = NVA.Decoder()
        decoder.append(Data([0x47, 0x45, 0x54, 0x20, 0x2F, 0x20]))
        XCTAssertThrowsError(try decoder.next())
    }

    // MARK: Play requests

    func testPlayVideo() {
        let request = CastRequest.parse(command: "Play", body: json(["aid": 170_001, "cid": 279_786, "epid": 0, "season_id": 0, "seekTs": 95, "content_type": 0]))
        XCTAssertEqual(request, CastRequest(content: .video(aid: 170_001, cid: 279_786), startAt: 95))
    }

    func testPlayEpisode() {
        let request = CastRequest.parse(command: "Play", body: json(["aid": 1, "cid": 2, "epid": 733_316, "season_id": 44_352, "seekTs": "30"]))
        XCTAssertEqual(request, CastRequest(content: .episode(epID: 733_316, seasonID: 44_352), startAt: 30))
    }

    func testPlayLive() {
        XCTAssertEqual(CastRequest.parse(command: "Play", body: json(["roomId": "21452505"]))?.content, .live(roomID: 21_452_505))
    }

    func testPlayUrlWrapsTheRequest() throws {
        let ext = String(data: json(["ver": 2, "content": ["aid": 5, "cid": 6, "seekTs": 7]]), encoding: .utf8)!
        var url = URLComponents(string: "https://www.bilibili.com/video/av5")!
        url.queryItems = [URLQueryItem(name: "nva_ext", value: ext)]
        let request = CastRequest.parse(command: "PlayUrl", body: json(["url": url.string!, "title": "x"]))
        XCTAssertEqual(request, CastRequest(content: .video(aid: 5, cid: 6), startAt: 7))
    }

    func testMalformedPlayIsIgnored() {
        XCTAssertNil(CastRequest.parse(command: "Play", body: nil))
        XCTAssertNil(CastRequest.parse(command: "Play", body: json(["cid": 2])))
        XCTAssertNil(CastRequest.parse(command: "Pause", body: json(["aid": 1])))
    }

    // MARK: Discovery

    func testSearchAnswers() {
        let search = { (st: String) in "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n" }
        XCTAssertEqual(CastDiscovery.answers(toSearch: search("ssdp:all")), CastDiscovery.targets)
        XCTAssertEqual(CastDiscovery.answers(toSearch: search(CastDiscovery.nirvanaService)), [CastDiscovery.nirvanaService])
        XCTAssertEqual(CastDiscovery.answers(toSearch: search("urn:schemas-upnp-org:device:MediaServer:1")), [])
        XCTAssertEqual(CastDiscovery.answers(toSearch: "NOTIFY * HTTP/1.1\r\nNT: upnp:rootdevice\r\n\r\n"), [])
    }

    func testSearchResponse() {
        let text = CastDiscovery.searchResponse(target: CastDiscovery.deviceType, uuid: "XYABC", location: "http://10.0.0.2:9958/description.xml")
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("\r\nUSN: uuid:XYABC::urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
        XCTAssertTrue(text.contains("\r\nLOCATION: http://10.0.0.2:9958/description.xml\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testDescriptionListsTheServicesTheAppNeeds() throws {
        let xml = CastDiscovery.description(uuid: "abc", name: "DanmuTV <Living Room>")
        for field in ["<manufacturer>Bilibili Inc.</manufacturer>", "<UDN>uuid:abc</UDN>", "DanmuTV &lt;Living Room&gt;",
                      CastDiscovery.nirvanaService, CastDiscovery.renderingService, CastDiscovery.connectionService,
                      "<controlURL>/AVTransport/action</controlURL>", "<SCPDURL>/dlna/NirvanaControl.xml</SCPDURL>"]
        {
            XCTAssertTrue(xml.contains(field), field)
        }
        #if os(macOS)
        XCTAssertNotNil(try XMLDocument(xmlString: xml))
        for name in ["AVTransport", "RenderingControl", "ConnectionManager", "NirvanaControl"] {
            let scpd = try XCTUnwrap(CastDiscovery.serviceDescription(named: name))
            XCTAssertNotNil(try XMLDocument(xmlString: scpd), name)
        }
        #endif
        XCTAssertTrue(CastDiscovery.serviceDescription(named: "NirvanaControl")!.contains("<name>PackageName</name><direction>out</direction>"))
        XCTAssertNil(CastDiscovery.serviceDescription(named: "Nope"))
    }

    func testDeviceID() {
        XCTAssertNotNil(UUID(uuidString: CastDiscovery.makeDeviceID()))
    }

    // MARK: HTTP

    func testHTTPRequestWithBody() throws {
        let raw = Data("POST /AVTransport/action HTTP/1.1\r\nContent-Length: 4\r\nSOAPAction: x\r\n\r\nbodyEXTRA".utf8)
        let parsed = try CastHTTPRequest.parse(raw)
        XCTAssertEqual(parsed?.request.method, "POST")
        XCTAssertEqual(parsed?.request.path, "/AVTransport/action")
        XCTAssertEqual(parsed?.request.headers["soapaction"], "x")
        XCTAssertEqual(parsed?.request.body, Data("body".utf8))
        XCTAssertEqual(parsed?.length, raw.count - 5)
        XCTAssertNil(try CastHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nbo".utf8)))
    }

    func testSetupRequest() throws {
        let raw = Data("SETUP /projection NVA/1.0\r\nSession: deadbeef\r\nNvaVersion: 1\r\n\r\n".utf8) + NVA.encode(.ping(seq: 1))
        let parsed = try CastHTTPRequest.parse(raw)
        XCTAssertEqual(parsed?.request.method, "SETUP")
        XCTAssertEqual(parsed?.request.headers["session"], "deadbeef")
        XCTAssertEqual(raw.count - (parsed?.length ?? 0), 6, "the frame after the head is left for the decoder")
    }

    func testHostileHTTPLengthsAreRejected() {
        for length in ["-5", "9223372036854775807", "abc", "70000"] {
            let raw = Data("POST /x HTTP/1.1\r\nContent-Length: \(length)\r\n\r\nbody".utf8)
            XCTAssertThrowsError(try CastHTTPRequest.parse(raw), length)
        }
        XCTAssertThrowsError(try CastHTTPRequest.parse(Data(repeating: 0x41, count: CastHTTPRequest.maxLength + 1)))
        XCTAssertThrowsError(try CastHTTPRequest.parse(Data("garbage\r\n\r\n".utf8)))
    }

    func testOversizedFrameIsRejectedBeforeBuffering() {
        var decoder = NVA.Decoder()
        var frame = Data([0xE0, 3, 0, 0, 0, 1, 1, 7]) + Data("Command".utf8) + Data([4]) + Data("Play".utf8)
        frame.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.next()) { XCTAssertEqual($0 as? NVA.DecodeError, .tooLarge(Int(UInt32.max))) }
    }

    func testLargeStreamDecodesInLinearChunks() throws {
        let frames = (1 ... 2000).map { NVA.Frame.command(seq: UInt32($0), name: "Seek", body: Data(#"{"seekTs":1}"#.utf8)) }
        var decoder = NVA.Decoder()
        decoder.append(frames.map(NVA.encode).reduce(Data(), +))
        var count = 0
        while try decoder.next() != nil { count += 1 }
        XCTAssertEqual(count, 2000)
    }
    // MARK: SOAP / DLNA

    /// SetAVTransportURI shaped like the official app's (structure after NeoBV's sample, MIT), with a synthetic
    /// `_nva_ext_`: same encoding and field names, no real account data.
    func testOfficialProjectionIdentityIsDecoded() throws {
        let long = "LIMmQLRJ5m-eajAT_LGUZhY1E5bKuVUq2iPxS3SzCjRbfaWqTRI7LfuzCPJFkpopnpf0OD8eiYe5qf66nGetX4G6SjEWUqhDcHrsIP-6xaQjS0S2DQGxVnOJupVrUb5Wgq7WVFFKNu3iu82Q8XRtW0Tlj6VLRGRPWZjLoEsA09rK8tma0wDZLy_YYBL6N15G0Rj2Ic9Z1XLUGk3m1N-n8A"
        let body = """
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>\
        <CurrentURI>bilibili://projection?proj_source=bilibili&amp;_nva_ext_=</CurrentURI>\
        <CurrentURIMetaData>&lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;&lt;item id="0" parentID="-1" restricted="1"&gt;&lt;dc:title&gt;测试视频&lt;/dc:title&gt;&lt;upnp:longDescription&gt;\(long)&lt;/upnp:longDescription&gt;&lt;res protocolInfo="http-get:*:video/x-flv:DLNA.ORG_OP=01;DLNA.ORG_CI=0"&gt;bilibili://projection?proj_source=bilibili&amp;amp;_nva_ext_=&lt;/res&gt;&lt;upnp:class&gt;object.item.videoItem&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>\
        </u:SetAVTransportURI></s:Body></s:Envelope>
        """
        let content = try XCTUnwrap(DLNAContent.parse(setURIBody: body))
        XCTAssertEqual(content.request, CastRequest(content: .video(aid: 117_410_329_855_933, cid: 42_594_076_299), startAt: 40))
        XCTAssertEqual(content.title, "测试视频")
        XCTAssertNil(content.mediaURL)
    }

    func testLiveRoomInPlainLongDescription() throws {
        let body = "<CurrentURI>bilibili://projection</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;upnp:longDescription&gt;{\"content\":{\"contentType\":3,\"roomId\":865961}}&lt;/upnp:longDescription&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>"
        XCTAssertEqual(DLNAContent.parse(setURIBody: body)?.request?.content, .live(roomID: 865_961))
    }

    func testPlainMediaURL() throws {
        let body = "<CurrentURI>http://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/66/24/42313582466/42313582466-1-192.mp4?e=x&amp;ua=tvproj</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        let content = try XCTUnwrap(DLNAContent.parse(setURIBody: body))
        XCTAssertNil(content.request)
        XCTAssertEqual(content.mediaURL?.absoluteString, "http://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/66/24/42313582466/42313582466-1-192.mp4?e=x&ua=tvproj")
    }

    func testSOAPHelpers() {
        XCTAssertEqual(SOAP.action(header: "\"urn:schemas-upnp-org:service:AVTransport:1#Seek\"")?.name, "Seek")
        XCTAssertEqual(SOAP.action(header: "\"urn:schemas-upnp-org:service:AVTransport:1#Seek\"")?.service, CastDiscovery.transportService)
        XCTAssertEqual(SOAP.element("Target", in: "<u:Seek><Unit>REL_TIME</Unit><Target>00:01:05</Target></u:Seek>"), "00:01:05")
        XCTAssertEqual(SOAP.seconds(fromTime: "01:02:03.500"), 3723.5)
        XCTAssertEqual(SOAP.time(3723.9), "01:02:03")
        let response = SOAP.response(service: CastDiscovery.renderingService, action: "GetVolume", values: [("CurrentVolume", "100")])
        XCTAssertTrue(response.contains("<u:GetVolumeResponse xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\"><CurrentVolume>100</CurrentVolume>"))
    }

    func testPlayInfo() throws {
        let status = CastStatus(state: .playing, position: 12.7, duration: 100, speed: 1.5, aid: 1, cid: 2, title: "t")
        let json = try JSON(data: Data(status.playInfoJSON.utf8))
        XCTAssertEqual(json["playerStatus"].intValue, 4)
        XCTAssertEqual(json["position"].intValue, 12)
        XCTAssertEqual(json["duration"].intValue, 100_000)
        XCTAssertEqual(json["aid"].stringValue, "1")
        XCTAssertEqual(json["speedInfo"]["currSpeed"].doubleValue, 1.5)
        XCTAssertEqual(status.transportState, "PLAYING")
    }
}
