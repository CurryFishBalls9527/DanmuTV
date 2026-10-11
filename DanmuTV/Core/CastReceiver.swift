import BiliKit
import Darwin
import Network
import UIKit

/// What the phone can do to the video player it cast to.
@MainActor
protocol CastControllable: AnyObject {
    /// Whether this is already playing that video part or episode (a repeated Play just seeks).
    func castIsPlaying(_ content: CastRequest.Content) -> Bool
    func castPause()
    func castResume()
    func castSeek(to seconds: Double)
    func castSetSpeed(_ rate: Double)
    func castSetDanmaku(_ on: Bool)
    /// What the phone shows (GetPlayInfo / GetPositionInfo).
    func castStatus() -> CastStatus
}

/// 投屏: makes this Apple TV show up in the official Bilibili app's cast list (as a 云视听小电视) and plays what
/// the phone sends. Runs while the app is in the foreground: SSDP on UDP 1900, descriptions and the NVA control
/// connection on TCP 9958.
@MainActor
final class CastReceiver {
    static let shared = CastReceiver()

    /// The video player on screen, if any (set by the player itself).
    weak var player: CastControllable?

    private var listener: NWListener?
    private var ssdp: SSDPResponder?
    /// Every open connection (description fetches too); `sessions` are the ones that set up casting.
    private var connections: [ObjectIdentifier: CastSession] = [:]
    private var sessions: [ObjectIdentifier: CastSession] = [:]
    private var lastProgress: (position: Int, duration: Int) = (-1, -1)
    private var lastState: NVA.PlayState?

    /// Kept across launches, so the phone remembers this TV.
    let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "cast.uuid") { return id }
        let id = CastDiscovery.makeDeviceID()
        UserDefaults.standard.set(id, forKey: "cast.uuid")
        return id
    }()

    /// The name in the phone's cast list.
    var deviceName: String { "Danmu TV · \(UIDevice.current.name)" }

    var isRunning: Bool { listener != nil }
    private var retryTask: Task<Void, Never>?

    func start() {
        guard listener == nil, AppSettings.shared.castEnabled else { return }
        listen(attempt: 0)
        guard ssdp == nil else { return }
        let ssdp = SSDPResponder(uuid: deviceID)
        ssdp.start()
        self.ssdp = ssdp
        Log.cast.info("cast: ready as \(self.deviceName, privacy: .public)")
    }

    /// The port can still be held by the previous listener for a moment after a quick background → foreground:
    /// retry a few times instead of giving up.
    private func listen(attempt: Int) {
        retryTask?.cancel()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Phones that leave the network without closing are dropped instead of lingering.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 3
        }
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: NVA.port)!) else {
            retry(after: attempt)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener, case let .failed(error) = state else { return }
                Log.cast.error("cast: listener failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                listener.cancel()
                self.listener = nil
                self.retry(after: attempt)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func retry(after attempt: Int) {
        guard attempt < 5, AppSettings.shared.castEnabled else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.ssdp != nil, self.listener == nil else { return }
            self.listen(attempt: attempt + 1)
        }
    }

    func stop() {
        retryTask?.cancel()
        ssdp?.stop()
        ssdp = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections = [:]
        sessions = [:]
    }

    /// For the setting: applies a change right away.
    func settingChanged() {
        if AppSettings.shared.castEnabled { start() } else { stop() }
    }

    // MARK: Player → phone

    func playerStateChanged(_ state: NVA.PlayState) {
        guard !sessions.isEmpty, state != lastState else { return }
        lastState = state
        if state == .stopped || state == .loading { lastProgress = (-1, -1) }
        broadcast("OnPlayState", ["playState": state.rawValue])
    }

    func playerProgress(position: Double, duration: Double) {
        guard !sessions.isEmpty, position.isFinite, duration.isFinite, duration > 0 else { return }
        let now = (Int(position), Int(duration))
        guard now != lastProgress else { return }
        lastProgress = now
        broadcast("OnProgress", ["duration": now.1, "position": now.0])
    }

    private func broadcast(_ name: String, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        sessions.values.forEach { $0.send(name, body: data) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let session = CastSession(connection: connection, uuid: deviceID, name: deviceName)
        let key = ObjectIdentifier(session)
        session.onCommand = { [weak self, weak session] name, body in
            guard let self, let session else { return }
            self.handle(name, body: body, from: session)
        }
        session.onClose = { [weak self] in
            self?.connections[key] = nil
            self?.sessions[key] = nil
        }
        session.onSOAP = { [weak self] service, action, body in
            self?.handleSOAP(service: service, action: action, body: body) ?? ""
        }
        session.onProjection = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessions[key] = session
            self.lastState = nil
            Log.cast.notice("cast: phone connected")
        }
        connections[key] = session
        session.start()
    }

    private func handle(_ name: String, body: Data?, from session: CastSession) {
        Log.cast.info("cast: \(name, privacy: .public)")
        let json = body.flatMap { try? JSON(data: $0) }
        switch name {
        case "GetVolume":
            session.reply(["volume": 50])
            return
        case "Play", "PlayUrl":
            if let request = CastRequest.parse(command: name, body: body) { play(request) }
        case "Pause":
            player?.castPause()
        case "Resume":
            player?.castResume()
        case "Seek":
            if let seconds = json?["seekTs"].double { player?.castSeek(to: seconds) }
        case "Stop":
            // Only a player: never a login sheet or alert that happens to be up.
            if PlayerLauncher.isPlayerShowing { PlayerLauncher.dismissPlayers {} }
        case "SwitchSpeed":
            if let rate = json?["speed"].double, rate > 0 { player?.castSetSpeed(rate) }
        case "SwitchDanmaku":
            if let json { player?.castSetDanmaku(json["open"].string == "true" || json["open"].intValue == 1) }
        default:
            break
        }
        session.reply(nil)
    }

    // MARK: UPnP (SOAP)

    /// The URI and metadata of the last SetAVTransportURI (echoed in GetPositionInfo / GetMediaInfo).
    private var currentURI = ""
    private var currentMetadata = ""

    private func handleSOAP(service name: String, action: String, body: String) -> String {
        guard let service = CastDiscovery.services.first(where: { $0.name == name })?.type else { return "" }
        Log.cast.info("cast soap: \(name, privacy: .public)#\(action, privacy: .public)")
        let status = player?.castStatus() ?? .stopped
        func value(_ tag: String) -> String? { SOAP.element(tag, in: body).map(SOAP.unescape) }
        var values: [(String, String)] = []
        switch (name, action) {
        case ("AVTransport", "SetAVTransportURI"):
            currentURI = value("CurrentURI") ?? ""
            currentMetadata = value("CurrentURIMetaData") ?? ""
            if let content = DLNAContent.parse(setURIBody: body) {
                Log.cast.notice("cast: SetAVTransportURI → \(String(describing: content.request?.content), privacy: .public) \(content.mediaURL?.host ?? "", privacy: .public)")
                if let request = content.request {
                    play(request)
                } else if let url = content.mediaURL {
                    DirectCastPlayer.play(url, title: content.title)
                }
            }
        case ("AVTransport", "Play"), ("NirvanaControl", "Play"):
            player?.castResume()
        case ("AVTransport", "Pause"), ("NirvanaControl", "Pause"):
            player?.castPause()
        case ("AVTransport", "Stop"), ("NirvanaControl", "Stop"):
            if PlayerLauncher.isPlayerShowing { PlayerLauncher.dismissPlayers {} }
        case ("AVTransport", "Seek"), ("NirvanaControl", "Seek"):
            if let target = value("Target"), let seconds = SOAP.seconds(fromTime: target) { player?.castSeek(to: seconds) }
        case ("NirvanaControl", "SetSpeed"):
            if let rate = value("Speed").flatMap(Double.init), rate > 0 { player?.castSetSpeed(rate) }
        case ("NirvanaControl", "SetDanmakuSwitch"):
            if let on = value("DesiredSwitch") { player?.castSetDanmaku(["1", "true", "on", "open"].contains(on.lowercased())) }
        case ("AVTransport", "GetTransportInfo"):
            values = [("CurrentTransportState", status.transportState), ("CurrentTransportStatus", "OK"), ("CurrentSpeed", "1")]
        case ("AVTransport", "GetPositionInfo"):
            values = [("Track", "1"), ("TrackDuration", SOAP.time(status.duration)), ("TrackMetaData", currentMetadata),
                      ("TrackURI", currentURI), ("RelTime", SOAP.time(status.position)), ("AbsTime", SOAP.time(status.position)),
                      ("RelCount", "2147483647"), ("AbsCount", "2147483647")]
        case ("AVTransport", "GetMediaInfo"):
            values = [("NrTracks", "1"), ("MediaDuration", SOAP.time(status.duration)), ("CurrentURI", currentURI),
                      ("CurrentURIMetaData", currentMetadata), ("NextURI", ""), ("NextURIMetaData", ""), ("PlayMedium", "NETWORK"),
                      ("RecordMedium", "NOT_IMPLEMENTED"), ("WriteStatus", "NOT_IMPLEMENTED")]
        case ("AVTransport", "GetCurrentTransportActions"):
            values = [("Actions", "Play,Pause,Seek,Stop")]
        case ("AVTransport", "GetDeviceCapabilities"):
            values = [("PlayMedia", "NETWORK"), ("RecMedia", "NOT_IMPLEMENTED"), ("RecQualityModes", "NOT_IMPLEMENTED")]
        case ("AVTransport", "GetTransportSettings"):
            values = [("PlayMode", "NORMAL"), ("RecQualityMode", "NOT_IMPLEMENTED")]
        case ("RenderingControl", "GetVolume"):
            values = [("CurrentVolume", "100")]
        case ("RenderingControl", "GetMute"):
            values = [("CurrentMute", "0")]
        case ("ConnectionManager", "GetProtocolInfo"):
            values = [("Source", ""), ("Sink", CastDiscovery.sinkProtocolInfo)]
        case ("ConnectionManager", "GetCurrentConnectionIDs"):
            values = [("ConnectionIDs", "0")]
        case ("ConnectionManager", "GetCurrentConnectionInfo"):
            values = [("RcsID", "0"), ("AVTransportID", "0"), ("ProtocolInfo", ""), ("PeerConnectionManager", ""),
                      ("PeerConnectionID", "-1"), ("Direction", "Input"), ("Status", "OK")]
        case ("NirvanaControl", "GetAppInfo"):
            // The official TV app's package (see CastInterop): what makes the phone send the video's identity.
            values = [("PackageName", CastInterop.packageName), ("AppKey", ""), ("Signature", ""), ("CurrentSignedIn", "0")]
        case ("NirvanaControl", "GetAccountInfo"):
            values = [("VipInfo", "0")]
        case ("NirvanaControl", "GetPlayInfo"):
            values = [("Content", status.playInfoJSON)]
        default:
            break
        }
        return SOAP.response(service: service, action: action, values: values)
    }

    private func play(_ request: CastRequest) {
        if let player, player.castIsPlaying(request.content) {
            if request.startAt > 0 { player.castSeek(to: request.startAt) }
            player.castResume()
            return
        }
        switch request.content {
        case let .video(aid, cid):
            PlayerLauncher.playCast(aid: aid, cid: cid, startAt: request.startAt)
        case let .episode(epID, seasonID):
            PlayerLauncher.playCast(seasonID: seasonID > 0 ? seasonID : nil, epID: epID, startAt: request.startAt)
        case let .live(roomID):
            LiveLauncher.open(LiveRoom(roomID: roomID, title: "", cover: "", uname: "", face: ""))
        }
    }
}

/// One TCP connection from a phone: HTTP requests (descriptions, UPnP actions) until `SETUP /projection`,
/// then NVA frames both ways.
@MainActor
private final class CastSession {
    var onCommand: ((String, Data?) -> Void)?
    /// (service name, action, body) → SOAP response.
    var onSOAP: ((String, String, String) -> String)?
    var onProjection: (() -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let uuid: String
    private let name: String
    private var buffer = Data()
    private var decoder: NVA.Decoder?
    /// Frames are numbered per connection; ours continue from the phone's.
    private var seq: UInt32 = 0
    private var closed = false

    init(connection: NWConnection, uuid: String, name: String) {
        self.connection = connection
        self.uuid = uuid
        self.name = name
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        // Description fetches finish within seconds; a connection that never sets up casting doesn't stay open.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.decoder == nil else { return }
            self.close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    func send(_ name: String, body: Data?) {
        seq &+= 1
        write(NVA.encode(.command(seq: seq, name: name, body: body)))
    }

    func reply(_ body: [String: Any]?) {
        seq &+= 1
        write(NVA.encode(.reply(seq: seq, body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) })))
    }

    private func write(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Closes once what was written has gone out (cancelling right away would drop it).
    private func closeAfterSending() {
        guard !closed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.consume(data) }
                if isComplete || error != nil { self.close() } else if !self.closed { self.receive() }
            }
        }
    }

    private func consume(_ data: Data) {
        if decoder != nil {
            decoder?.append(data)
            readFrames()
            return
        }
        buffer.append(data)
        do {
            while decoder == nil, let (request, length) = try CastHTTPRequest.parse(buffer) {
                buffer.removeFirst(length)
                respond(to: request)
            }
        } catch {
            Log.cast.error("cast: malformed request, closing")
            write(head("HTTP/1.1 400 Bad Request", [("Content-Length", "0")]))
            closeAfterSending()
            return
        }
        if decoder != nil, !buffer.isEmpty {
            decoder?.append(buffer)
            buffer = Data()
            readFrames()
        }
    }

    private func readFrames() {
        do {
            while let frame = try decoder?.next() {
                switch frame {
                case let .command(seq, name, body):
                    self.seq = seq
                    onCommand?(name, body)
                case .reply, .ping:
                    break
                }
            }
        } catch {
            Log.cast.error("cast: bad frame, closing: \(String(describing: error), privacy: .public)")
            close()
        }
    }

    private func respond(to request: CastHTTPRequest) {
        // Bodies stay out of the log: the phone's _nva_ext_ carries an access key.
        Log.cast.info("cast http: \(request.method, privacy: .public) \(request.path, privacy: .public)")
        if request.method == "SETUP" || request.method == "RESTORE", request.path.hasPrefix("/projection") {
            write(head("NVA/1.0 200 OK", [
                ("Session", request.headers["session"] ?? ""),
                ("NvaVersion", "1"),
                ("Connection", "Keep-Alive"),
                ("UUID", uuid),
                ("User-Agent", CastDiscovery.server),
            ]))
            decoder = NVA.Decoder()
            onProjection?()
            return
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("GET", "/description.xml"):
            http(200, xml: CastDiscovery.description(uuid: uuid, name: name))
        case ("GET", _) where path.hasPrefix("/dlna/") && path.hasSuffix(".xml"):
            let name = String(path.dropFirst("/dlna/".count).dropLast(".xml".count))
            if let xml = CastDiscovery.serviceDescription(named: name) { http(200, xml: xml) } else { notFound() }
        case ("POST", _) where path.hasSuffix("/action") || path.hasSuffix("/control"):
            let name = path.split(separator: "/").first.map(String.init) ?? ""
            let action = SOAP.action(header: request.headers["soapaction"])?.name ?? ""
            http(200, xml: onSOAP?(name, action, String(decoding: request.body, as: UTF8.self)) ?? "")
        case ("SUBSCRIBE", _), ("UNSUBSCRIBE", _):
            write(head("HTTP/1.1 200 OK", [("SID", "uuid:\(uuid)"), ("TIMEOUT", "Second-1800"), ("Content-Length", "0")]))
        default:
            notFound()
        }
        if request.headers["connection"]?.lowercased() == "close" { closeAfterSending() }
    }

    private func notFound() {
        write(head("HTTP/1.1 404 Not Found", [("Content-Length", "0")]))
    }

    private func http(_ status: Int, xml: String) {
        let body = Data(xml.utf8)
        write(head("HTTP/1.1 \(status) OK", [
            ("Content-Type", "text/xml; charset=\"utf-8\""),
            ("Content-Length", "\(body.count)"),
            ("Server", CastDiscovery.server),
        ]) + body)
    }

    private func head(_ status: String, _ headers: [(String, String)]) -> Data {
        Data((([status] + headers.map { "\($0): \($1)" }).joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// Answers SSDP searches and announces the TV every few seconds, on every local IPv4 interface.
/// BSD sockets on a background thread (UDP multicast).
private final class SSDPResponder: @unchecked Sendable {
    private let uuid: String
    private let lock = NSLock()
    private var running = false
    private var fd: Int32 = -1
    private let generation: Int

    private static let generationLock = NSLock()
    private static var latestGeneration = 0

    private static func isLatest(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == latestGeneration
    }

    init(uuid: String) {
        self.uuid = uuid
        Self.generationLock.lock()
        Self.latestGeneration += 1
        generation = Self.latestGeneration
        Self.generationLock.unlock()
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "DanmuTV.ssdp"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private struct Interface {
        var address: in_addr
        var mask: in_addr
        var text: String
    }

    private func run() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = CastDiscovery.multicastPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            Log.cast.error("cast: can't bind SSDP port (errno \(errno))")
            return
        }

        var lastNotify = Date.distantPast
        var interfaces: [Interface] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        while isRunning {
            if Date().timeIntervalSince(lastNotify) >= 5 {
                lastNotify = Date()
                interfaces = Self.interfaces()
                for interface in interfaces {
                    // Re-joined every round: after a Wi-Fi drop the kernel forgets the membership even if the
                    // address comes back the same (joining again when still a member just fails harmlessly).
                    var request = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(CastDiscovery.multicastHost)), imr_interface: interface.address)
                    setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size))
                    announce(on: interface)
                }
            }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0, let message = String(bytes: buffer[0 ..< count], encoding: .utf8) else { continue }
            let targets = CastDiscovery.answers(toSearch: message)
            guard !targets.isEmpty,
                  let interface = interfaces.first(where: { $0.address.s_addr & $0.mask.s_addr == from.sin_addr.s_addr & $0.mask.s_addr }) ?? interfaces.first
            else { continue }
            for target in targets {
                let text = CastDiscovery.searchResponse(target: target, uuid: uuid, location: location(interface))
                send(text, to: from)
            }
        }
        // Tell phones the TV is gone, so it drops out of their list right away — unless a newer responder already
        // took over (quick background → foreground), whose `alive` this would cancel.
        guard Self.isLatest(generation) else { return }
        for interface in Self.interfaces() {
            setMulticastInterface(interface)
            for target in CastDiscovery.targets {
                send(CastDiscovery.notify(target: target, uuid: uuid, location: location(interface), alive: false), to: Self.multicastAddress)
            }
        }
    }

    private func location(_ interface: Interface) -> String {
        "http://\(interface.text):\(NVA.port)/description.xml"
    }

    private func announce(on interface: Interface) {
        setMulticastInterface(interface)
        for target in CastDiscovery.targets {
            send(CastDiscovery.notify(target: target, uuid: uuid, location: location(interface)), to: Self.multicastAddress)
        }
    }

    private func setMulticastInterface(_ interface: Interface) {
        var address = interface.address
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size))
    }

    private static var multicastAddress: sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = CastDiscovery.multicastPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(CastDiscovery.multicastHost))
        return address
    }

    private func send(_ text: String, to address: sockaddr_in) {
        var address = address
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Active IPv4 interfaces on the local network (Ethernet / Wi-Fi), not loopback or tunnels.
    private static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET), let mask = entry.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0,
                  String(cString: entry.ifa_name).hasPrefix("en")
            else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            result.append(Interface(address: address, mask: netmask, text: String(cString: inet_ntoa(address))))
        }
        return result
    }
}
