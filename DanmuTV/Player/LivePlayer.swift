import AVKit
import BiliKit
import SwiftUI
import UIKit
import VideoToolbox
import VLCKitSPM

/// Live chat over the video: scrolling danmaku (shared renderer, wall clock), pinned 醒目留言,
/// a viewer-count badge and connection hints.
@MainActor
final class LiveChatOverlay: UIView {
    private let renderer = DanmakuRenderer()
    private let superChats = UIStackView()
    private let badge = HUDPill()
    private var hosts: [UIHostingController<SuperChatCard>] = []
    private var client: LiveDanmakuClient?
    private var listenTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var filter = DanmakuFilter()
    private var pinned: [(controller: UIHostingController<SuperChatCard>, until: Date)] = []
    private(set) var popularity = 0
    /// Toasts (e.g. 弹幕已断开) go through the owner.
    var onNotice: ((String) -> Void)?

    var danmakuEnabled = true {
        didSet {
            renderer.isHidden = !danmakuEnabled
            if !danmakuEnabled { renderer.clear() }
        }
    }

    var superChatEnabled = true {
        didSet { superChats.isHidden = !superChatEnabled }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(renderer)

        // Pinned top-right, natural height: cards keep their size instead of stretching.
        superChats.axis = .vertical
        superChats.spacing = 14
        superChats.alignment = .trailing
        superChats.translatesAutoresizingMaskIntoConstraints = false
        addSubview(superChats)
        NSLayoutConstraint.activate([
            superChats.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            superChats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -60),
            superChats.widthAnchor.constraint(equalToConstant: 480),
        ])

        addSubview(badge)

        let settings = AppSettings.shared
        renderer.style = .init(fontSize: settings.danmakuFontSize, scrollDuration: settings.danmakuDuration,
                               opacity: Float(settings.danmakuOpacity), area: settings.danmakuArea)
        danmakuEnabled = settings.danmakuEnabled
        superChatEnabled = settings.liveShowSuperChat
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.frame = bounds
        if popularity > 1 { badge.show("人气 \(BiliText.formatCount(popularity))", in: bounds, corner: .topLeading, autoHide: nil) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: LiveLinkProxy(self), selector: #selector(LiveLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func start(roomID: Int) {
        stop()
        // Same rules as video danmaku (weight levels don't apply: live comments carry none).
        filter = PlayerOverlayView.danmakuFilter(accountRules: AccountDanmakuRules.cached)
        filter.minWeight = 0
        let client = LiveDanmakuClient(roomID: roomID)
        self.client = client
        listenTask = Task { [weak self] in
            for await event in client.events() {
                self?.handle(event)
            }
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        client?.stop()
        client = nil
        renderer.clear()
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case let .danmaku(d, _):
            guard danmakuEnabled, filter.allows(d) else { return }
            renderer.showWhenReady(d) { CACurrentMediaTime() }
        case let .superChat(sc):
            guard superChatEnabled else { return }
            pin(sc)
        case let .popularity(n):
            popularity = n
            if n > 1 { badge.show("人气 \(BiliText.formatCount(n))", in: bounds, corner: .topLeading, autoHide: nil) } else { badge.hide() }
        case .connected:
            Log.player.info("live chat connected")
        case let .disconnected(reason):
            Log.player.error("live chat disconnected: \(reason, privacy: .public)")
            onNotice?("弹幕已断开，正在重连…")
        }
    }

    private func pin(_ sc: SuperChat) {
        let host = UIHostingController(rootView: SuperChatCard(sc: sc))
        host.view.backgroundColor = .clear
        superChats.insertArrangedSubview(host.view, at: 0)
        pinned.append((host, Date().addingTimeInterval(TimeInterval(min(max(sc.duration, 10), 120)))))
        // Keep the column short.
        while pinned.count > 4 {
            pinned.removeFirst().controller.view.removeFromSuperview()
        }
    }

    fileprivate func tick() {
        renderer.step(now: CACurrentMediaTime())
        let now = Date()
        for entry in pinned where entry.until < now {
            entry.controller.view.removeFromSuperview()
        }
        pinned.removeAll { $0.until < now }
    }
}

private final class LiveLinkProxy: NSObject {
    weak var view: LiveChatOverlay?
    init(_ view: LiveChatOverlay) { self.view = view }
    @MainActor @objc func tick() { view?.tick() }
}

/// 醒目留言: a material card whose tier colour runs down the leading edge and tints the price.
struct SuperChatCard: View {
    let sc: SuperChat

    var body: some View {
        let color = Color(red: Double((sc.color >> 16) & 0xFF) / 255, green: Double((sc.color >> 8) & 0xFF) / 255,
                          blue: Double(sc.color & 0xFF) / 255)
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 8)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Avatar(url: sc.face, size: 36)
                    Text(sc.user).font(Theme.Font.caption.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text("¥\(sc.price)")
                        .font(Theme.Font.badge)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(color, in: Capsule())
                }
                Text(sc.message).font(Theme.Font.meta).lineLimit(3)
            }
            .padding(16)
        }
        .foregroundStyle(.white)
        .frame(width: 480, alignment: .leading)
        .background(color.opacity(0.25))
        .background(.thinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Opens a live room with the right player: AVPlayer for HLS, VLC for FLV (when forced in Settings
/// or when the room offers no HLS).
@MainActor
enum LiveLauncher {
    private static var opening = false

    static func open(_ room: LiveRoom) {
        guard !opening else { return } // double press
        opening = true
        Task {
            defer { opening = false }
            do {
                var room = room
                if room.title.isEmpty || room.uname.isEmpty, let info = try? await API.liveRoomInfo(roomID: room.roomID) {
                    room.title = info.title
                    room.cover = info.cover
                    room.area = info.area
                    if room.uname.isEmpty { room.uname = info.uname }
                }
                let info = try await API.livePlayInfo(roomID: room.roomID)
                guard info.isLive else {
                    PlayerLauncher.showError(room.uname.isEmpty ? "该直播间现在没有在直播" : "「\(room.uname)」现在没有在直播")
                    return
                }
                let forceVLC = AppSettings.shared.liveForceVLC
                let hls = info.preferredStream(useVLC: false, allowHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
                if !forceVLC, hls?.isHLS == true {
                    PlayerLauncher.present(LivePlayerViewController(room: room, info: info))
                } else if info.preferredStream(useVLC: true, allowHEVC: false) != nil {
                    PlayerLauncher.present(VLCLivePlayerViewController(room: room, info: info))
                } else {
                    PlayerLauncher.showError("没有可播放的直播流")
                }
            } catch {
                PlayerLauncher.showError(error.localizedDescription)
            }
        }
    }
}

/// Native player for HLS live streams.
final class LivePlayerViewController: AVPlayerViewController, PlayerTeardown {
    private let room: LiveRoom
    private var info: LivePlayInfo
    private var routeIndex = 0
    private var refetchedAfterFailure = false
    private let chat = LiveChatOverlay()
    private let toast = HUDPill()
    private var statusObservation: NSKeyValueObservation?
    private var tornDown = false

    init(room: LiveRoom, info: LivePlayInfo) {
        self.room = room
        self.info = info
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 竖屏直播间: aspect fit, never cropped.
        videoGravity = .resizeAspect
        chat.frame = contentOverlayView?.bounds ?? view.bounds
        chat.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        chat.onNotice = { [weak self] text in self?.showToast(text) }
        contentOverlayView?.addSubview(chat)
        configureToast()
        chat.start(roomID: info.roomID > 0 ? info.roomID : room.roomID)
        play()
        updateMenus()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { teardown() }
    }

    /// 退出直播后立即释放音频.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        chat.stop()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private var stream: LiveStream? {
        info.preferredStream(useVLC: false, allowHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
    }

    private func play() {
        guard let stream, stream.urls.indices.contains(routeIndex), let url = URL(string: stream.urls[routeIndex]) else { return }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": BiliClient.userAgent,
                                                                                   "Referer": "https://live.bilibili.com"]])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = [
            Self.metadata(.commonIdentifierTitle, room.title),
            Self.metadata(.iTunesMetadataTrackSubTitle, [room.uname, room.area].filter { !$0.isEmpty }.joined(separator: " · ")),
        ]
        // Stay close to the live edge.
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = CMTime(seconds: 6, preferredTimescale: 1)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.routeFailed(item.error) }
        }
        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            #if DEBUG
            player.isMuted = UserDefaults.standard.bool(forKey: "muted")
            #endif
            self.player = player
        }
        player?.play()
    }

    /// One route failing moves to the next. When all fail, fetch fresh URLs once (tokens expire,
    /// CDN nodes rotate); if the room went offline, say so.
    private func routeFailed(_ error: Error?) {
        guard !tornDown else { return }
        if let stream, routeIndex + 1 < stream.urls.count {
            routeIndex += 1
            Log.player.error("live route failed, trying route \(self.routeIndex + 1)")
            play()
            updateMenus()
            return
        }
        guard !refetchedAfterFailure else {
            showFinalError(error?.localizedDescription ?? "未知错误")
            return
        }
        refetchedAfterFailure = true
        Task {
            guard let fresh = try? await API.livePlayInfo(roomID: room.roomID, quality: info.currentQuality) else {
                showFinalError(error?.localizedDescription ?? "网络错误")
                return
            }
            guard fresh.isLive else {
                showFinalError("主播已下播", title: "直播已结束")
                return
            }
            info = fresh
            routeIndex = 0
            play()
            updateMenus()
        }
    }

    private func showFinalError(_ message: String, title: String = "直播播放失败") {
        guard presentedViewController == nil, !tornDown else { return }
        let alert = UIAlertController(title: title, message: message + (title == "直播播放失败" ? "\n可在设置中开启「直播使用 VLC 播放器」后重试。" : ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }

    private func reload(quality: Int) {
        Task {
            guard let fresh = try? await API.livePlayInfo(roomID: room.roomID, quality: quality) else { return }
            info = fresh
            routeIndex = 0
            refetchedAfterFailure = false
            play()
            updateMenus()
        }
    }

    private func updateMenus() {
        let qualities = UIMenu(title: "清晰度", subtitle: info.qualities.first { $0.qn == info.currentQuality }?.name,
                               image: UIImage(systemName: "slider.horizontal.3"), options: .singleSelection,
                               children: info.qualities.map { q in
                                   UIAction(title: q.name, state: q.qn == info.currentQuality ? .on : .off) { [weak self] _ in self?.reload(quality: q.qn) }
                               })
        let routes = UIMenu(title: "线路", subtitle: "线路 \(routeIndex + 1)", image: UIImage(systemName: "point.3.connected.trianglepath.dotted"),
                            options: .singleSelection,
                            children: (stream?.urls.indices ?? 0 ..< 0).map { i in
                                UIAction(title: "线路 \(i + 1)", state: i == routeIndex ? .on : .off) { [weak self] _ in
                                    self?.routeIndex = i
                                    self?.play()
                                    self?.updateMenus()
                                }
                            })
        let danmaku = UIAction(title: chat.danmakuEnabled ? "关闭弹幕" : "开启弹幕", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
            guard let self else { return }
            self.chat.danmakuEnabled.toggle()
            self.updateMenus()
        }
        let sc = UIAction(title: chat.superChatEnabled ? "隐藏醒目留言" : "显示醒目留言", image: UIImage(systemName: "yensign.circle")) { [weak self] _ in
            guard let self else { return }
            self.chat.superChatEnabled.toggle()
            self.updateMenus()
        }
        transportBarCustomMenuItems = [qualities, routes, UIMenu(title: "弹幕", image: UIImage(systemName: "text.bubble"), children: [danmaku, sc])]
    }

    private func configureToast() {
        contentOverlayView?.addSubview(toast)
    }

    private func showToast(_ text: String) {
        toast.show(text, in: contentOverlayView?.bounds ?? view.bounds, corner: .topTrailing)
    }

    private static func metadata(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

/// VLC-based player for FLV live streams (直播强制使用 VLC 播放器). VLC has no tvOS transport UI, so
/// this adds its own: a status overlay on any press, Down for options, Right for the next route.
final class VLCLivePlayerViewController: UIViewController, PlayerTeardown, VLCMediaPlayerDelegate {
    private let room: LiveRoom
    private var info: LivePlayInfo
    private let videoView = UIView()
    private let chat = LiveChatOverlay()
    private let status = HUDPanel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let mediaPlayer = VLCMediaPlayer()
    private var routeIndex = 0
    private var reconnects = 0
    private var tornDown = false

    init(room: LiveRoom, info: LivePlayInfo) {
        self.room = room
        self.info = info
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        chat.frame = view.bounds
        chat.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        chat.onNotice = { [weak self] text in self?.showStatus(text) }
        view.addSubview(chat)

        view.addSubview(status)

        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)

        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "muted") { mediaPlayer.audio?.isMuted = true }
        #endif
        chat.start(roomID: info.roomID > 0 ? info.roomID : room.roomID)
        play()
        showStatus(nil)
    }

    private var stream: LiveStream? { info.preferredStream(useVLC: true, allowHEVC: false) }

    private func play() {
        guard let stream, stream.urls.indices.contains(routeIndex), let url = URL(string: stream.urls[routeIndex]) else { return }
        let media = VLCMedia(url: url)
        media.addOption(":http-referrer=https://live.bilibili.com")
        media.addOption(":network-caching=1500")
        mediaPlayer.media = media
        mediaPlayer.play()
        spinner.startAnimating()
    }

    // MARK: VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_: Notification) {
        Task { @MainActor in self.stateChanged() }
    }

    private func stateChanged() {
        guard !tornDown else { return }
        switch mediaPlayer.state {
        case .playing:
            spinner.stopAnimating()
            reconnects = 0
        case .buffering, .opening:
            if !mediaPlayer.isPlaying { spinner.startAnimating() }
        case .ended, .error, .stopped:
            // The CDN closes FLV connections after a while: reconnect, rotating routes, then refresh URLs.
            reconnect()
        default:
            break
        }
    }

    private func reconnect() {
        guard !tornDown, reconnects < 6 else {
            if reconnects >= 6 { showStatus("直播连接失败，请稍后再试") }
            return
        }
        reconnects += 1
        spinner.startAnimating()
        Task {
            try? await Task.sleep(nanoseconds: UInt64(reconnects) * 1_000_000_000)
            guard !tornDown else { return }
            if reconnects % 2 == 0, let fresh = try? await API.livePlayInfo(roomID: room.roomID, quality: info.currentQuality) {
                guard fresh.isLive else {
                    spinner.stopAnimating()
                    showStatus("主播已下播")
                    return
                }
                info = fresh
                routeIndex = 0
            } else if let count = stream?.urls.count, count > 1 {
                routeIndex = (routeIndex + 1) % count
            }
            play()
        }
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return super.pressesBegan(presses, with: event) }
        switch press.type {
        case .menu:
            dismiss(animated: true)
        case .playPause, .select:
            if mediaPlayer.isPlaying {
                mediaPlayer.pause()
                showStatus("已暂停")
            } else {
                mediaPlayer.play()
                showStatus(nil)
            }
        case .rightArrow:
            let count = stream?.urls.count ?? 1
            routeIndex = (routeIndex + 1) % max(1, count)
            play()
            showStatus("切换到线路 \(routeIndex + 1)")
        case .downArrow:
            showOptions()
        default:
            showStatus(nil)
            super.pressesBegan(presses, with: event)
        }
    }

    /// Presses handled in pressesBegan are consumed: keep began/ended balanced.
    private static let handled: Set<UIPress.PressType> = [.menu, .playPause, .select, .rightArrow, .downArrow]

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let type = presses.first?.type, Self.handled.contains(type) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let type = presses.first?.type, Self.handled.contains(type) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func showStatus(_ message: String?) {
        let quality = info.qualities.first { $0.qn == info.currentQuality }?.name ?? ""
        let routes = stream?.urls.count ?? 1
        var lines = ["\(quality) · 线路 \(routeIndex + 1)/\(routes) · VLC"]
        if chat.popularity > 1 { lines.append("人气 \(BiliText.formatCount(chat.popularity))") }
        if let message { lines.append(message) }
        lines.append("按下：选项　　向右：换线路　　播放/暂停：暂停")
        status.titleLabel.text = room.uname.isEmpty ? room.title : "\(room.uname) · \(room.title)"
        status.bodyLabel.text = lines.joined(separator: "\n")
        status.layout(in: view.bounds, placement: .topLeading)
        status.show(autoHide: 4)
    }

    private func showOptions() {
        let sheet = UIAlertController(title: room.title, message: nil, preferredStyle: .actionSheet)
        for q in info.qualities {
            sheet.addAction(UIAlertAction(title: (q.qn == info.currentQuality ? "✓ " : "") + q.name, style: .default) { [weak self] _ in
                self?.changeQuality(q.qn)
            })
        }
        sheet.addAction(UIAlertAction(title: chat.danmakuEnabled ? "关闭弹幕" : "开启弹幕", style: .default) { [weak self] _ in
            self?.chat.danmakuEnabled.toggle()
        })
        sheet.addAction(UIAlertAction(title: chat.superChatEnabled ? "隐藏醒目留言" : "显示醒目留言", style: .default) { [weak self] _ in
            self?.chat.superChatEnabled.toggle()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func changeQuality(_ qn: Int) {
        Task {
            guard let fresh = try? await API.livePlayInfo(roomID: room.roomID, quality: qn) else { return }
            info = fresh
            routeIndex = 0
            play()
            showStatus(nil)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { teardown() }
    }

    /// 退出直播后立即释放音频. VLC's stop() blocks on network streams, so it runs off the main thread.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        chat.stop()
        status.cancelAutoHide()
        mediaPlayer.delegate = nil
        mediaPlayer.audio?.isMuted = true
        let player = mediaPlayer
        DispatchQueue.global(qos: .userInitiated).async {
            player.stop()
            player.media = nil
        }
    }
}
