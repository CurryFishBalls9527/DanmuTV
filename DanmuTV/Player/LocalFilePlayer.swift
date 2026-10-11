import AMSMB2
import BiliKit
import UIKit
import VLCKitSPM

/// Plays a video from an SMB share with VLC (any container/codec VLC supports), with its own
/// transport overlay, per-file resume and optional danmaku from a same-named .xml file.
final class LocalFilePlayerViewController: UIViewController, PlayerTeardown, VLCMediaPlayerDelegate {
    private let server: SMBServer
    private let share: String
    private let path: String
    private let titleText: String
    private let danmakuPath: String?
    private let subtitlePaths: [String]
    private var smoother = MediaTimeSmoother()
    private var lastSaved: CFTimeInterval = 0
    private var lastHUDUpdate: CFTimeInterval = 0
    private var finished = false
    private var resignObserver: NSObjectProtocol?

    private let videoView = UIView()
    private let renderer = DanmakuRenderer()
    private let hud = HUDPanel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let mediaPlayer = VLCMediaPlayer()
    private var timeline = DanmakuTimeline()
    private var clock = DanmakuClock()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var hideHUD: Task<Void, Never>?
    private var tornDown = false
    private var danmakuOn = AppSettings.shared.danmakuEnabled
    private var resumed = false

    private var resumeKey: String { "local.resume.\(server.id.uuidString)/\(share)/\(path)" }

    init(server: SMBServer, share: String, path: String, title: String, danmakuPath: String?, subtitlePaths: [String] = []) {
        self.server = server
        self.share = share
        self.path = path
        titleText = title
        self.danmakuPath = danmakuPath
        self.subtitlePaths = subtitlePaths
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
        renderer.frame = view.bounds
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let settings = AppSettings.shared
        renderer.style = .init(fontSize: settings.danmakuFontSize, scrollDuration: settings.danmakuDuration,
                               opacity: Float(settings.danmakuOpacity), area: settings.danmakuArea)
        renderer.isHidden = !danmakuOn
        view.addSubview(renderer)
        buildHUD()
        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.addSubview(spinner)
        spinner.startAnimating()

        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "muted") { mediaPlayer.audio?.isMuted = true }
        #endif
        guard let url = server.mediaURL(share: share, path: path) else {
            spinner.stopAnimating()
            showHUD(message: "无法打开：共享地址或路径无效")
            return
        }
        let media = VLCMedia(url: url)
        let (domain, user) = server.domainAndUser
        if !user.isEmpty {
            media.addOption(":smb-user=\(user)")
            media.addOption(":smb-pwd=\(server.password)")
            if !domain.isEmpty { media.addOption(":smb-domain=\(domain)") }
        }
        media.addOption(":network-caching=1500")
        // 继续播放: start at the saved spot directly (no flash of the opening).
        let saved = UserDefaults.standard.double(forKey: resumeKey)
        if let start = LocalResume.startPosition(saved: saved, length: 0) {
            media.addOption(":start-time=\(Int(start))")
            showHUD(message: "从 \(BiliText.formatDuration(Int(start))) 继续播放")
        } else {
            showHUD()
        }
        resumed = true
        mediaPlayer.media = media
        for sub in subtitlePaths {
            if let subURL = server.mediaURL(share: share, path: sub) {
                mediaPlayer.addPlaybackSlave(subURL, type: .subtitle, enforce: false)
            }
        }
        mediaPlayer.play()
        loadDanmaku()
        addSwipes()
        // Save progress when the app leaves the foreground (it may be killed there).
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress()
                self?.mediaPlayer.pause()
            }
        }
    }

    /// Siri Remote swipes don't arrive as presses: down = options, left/right = jump.
    private func addSwipes() {
        for (direction, action) in [(UISwipeGestureRecognizer.Direction.down, #selector(swipeDown)),
                                    (.left, #selector(swipeLeft)), (.right, #selector(swipeRight))]
        {
            let swipe = UISwipeGestureRecognizer(target: self, action: action)
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
    }

    @objc private func swipeDown() { showOptions() }
    @objc private func swipeLeft() { jump(-10) }
    @objc private func swipeRight() { jump(10) }

    private func jump(_ seconds: Int32) {
        if seconds < 0 { mediaPlayer.jumpBackward(-seconds) } else { mediaPlayer.jumpForward(seconds) }
        showHUD(message: seconds < 0 ? "后退 10 秒" : "前进 10 秒")
    }

    private func saveProgress() {
        guard !finished else { return }
        let position = Double(mediaPlayer.time.intValue) / 1000
        if position > 5 { UserDefaults.standard.set(position, forKey: resumeKey) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard displayLink == nil, !tornDown else { return }
        let link = CADisplayLink(target: LocalLinkProxy(self), selector: #selector(LocalLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: Danmaku from a sidecar .xml

    private func loadDanmaku() {
        guard let danmakuPath, let manager = SMBStore.shared.manager(for: server) else { return }
        Task { [weak self, share] in
            do {
                try await manager.connectShare(name: share)
                let data = try await manager.contents(atPath: danmakuPath)
                // Exported danmaku files are plain XML; some tools keep the API's raw deflate.
                let xml = data.first == UInt8(ascii: "<") ? data : ((try? (data as NSData).decompressed(using: .zlib) as Data) ?? data)
                let items = DanmakuParser.parseXML(xml)
                guard let self else { return }
                var t = DanmakuTimeline()
                t.add(DanmakuMerger.merge(items.filter(PlayerOverlayView.danmakuFilter(accountRules: []).allows)), segment: 1)
                self.timeline = t
                Log.player.info("local danmaku: \(items.count) comments")
            } catch {
                Log.player.error("local danmaku failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        let playing = mediaPlayer.isPlaying
        // VLC's time updates ~4×/s: smooth it so danmaku scroll instead of stepping.
        let now = smoother.update(reported: Double(mediaPlayer.time.intValue) / 1000, playing: playing,
                                  rate: Double(mediaPlayer.rate), elapsed: elapsed)
        if link.timestamp - lastHUDUpdate > 0.25 {
            lastHUDUpdate = link.timestamp
            updateHUDTime()
        }
        if playing, link.timestamp - lastSaved > 10 {
            lastSaved = link.timestamp
            saveProgress()
        }
        guard danmakuOn, !timeline.items.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch clock.advance(to: now, rate: playing ? Double(mediaPlayer.rate) : 0, elapsed: elapsed) {
        case .idle: break
        case let .window(from, to): renderer.show(timeline.due(from: from, to: to), at: now)
        case let .seek(from, to):
            renderer.clear()
            renderer.show(timeline.due(from: from, to: to), at: now)
        }
        renderer.step(now: now)
        CATransaction.commit()
    }

    // MARK: VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_: Notification) {
        Task { @MainActor in
            guard !self.tornDown else { return }
            switch self.mediaPlayer.state {
            case .playing: self.spinner.stopAnimating()
            case .buffering, .opening: if !self.mediaPlayer.isPlaying { self.spinner.startAnimating() }
            case .error:
                self.spinner.stopAnimating()
                self.showHUD(message: "无法播放：请检查共享权限或文件格式")
            case .ended:
                let time = Double(self.mediaPlayer.time.intValue) / 1000
                let length = Double(self.mediaPlayer.media?.length.intValue ?? 0) / 1000
                // VLC also reports .ended after open/read failures: only a real finish clears progress.
                guard LocalResume.isCompletion(time: time, length: length) else {
                    self.spinner.stopAnimating()
                    self.showHUD(message: "播放中断：请检查网络或共享是否可用")
                    return
                }
                self.finished = true
                UserDefaults.standard.removeObject(forKey: self.resumeKey)
                (self.presentingViewController ?? self).dismiss(animated: true)
            default: break
            }
        }
    }

    // MARK: Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return super.pressesBegan(presses, with: event) }
        switch press.type {
        case .menu:
            dismiss(animated: true)
        case .playPause, .select:
            if mediaPlayer.isPlaying { mediaPlayer.pause() } else { mediaPlayer.play() }
            showHUD()
        case .leftArrow:
            jump(-10)
        case .rightArrow:
            jump(10)
        case .downArrow:
            showOptions()
        default:
            showHUD()
            super.pressesBegan(presses, with: event)
        }
    }

    /// Presses handled above are consumed: keep began/ended balanced for the responder chain.
    private static let handled: Set<UIPress.PressType> = [.menu, .playPause, .select, .leftArrow, .rightArrow, .downArrow]

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let type = presses.first?.type, Self.handled.contains(type) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let type = presses.first?.type, Self.handled.contains(type) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func showOptions() {
        let sheet = UIAlertController(title: titleText, message: nil, preferredStyle: .actionSheet)
        if !timeline.items.isEmpty {
            sheet.addAction(UIAlertAction(title: danmakuOn ? "关闭弹幕" : "开启弹幕", style: .default) { [weak self] _ in
                guard let self else { return }
                self.danmakuOn.toggle()
                self.renderer.isHidden = !self.danmakuOn
                self.renderer.clear()
                self.clock.reset()
            })
        }
        // Embedded audio / subtitle tracks (MKV).
        let audioNames = mediaPlayer.audioTrackNames as? [String] ?? []
        let audioIDs = mediaPlayer.audioTrackIndexes as? [NSNumber] ?? []
        if audioIDs.count > 2 {
            for (name, id) in zip(audioNames, audioIDs) where id.int32Value >= 0 {
                sheet.addAction(UIAlertAction(title: (mediaPlayer.currentAudioTrackIndex == id.int32Value ? "✓ 音轨：" : "音轨：") + name, style: .default) { [weak self] _ in
                    self?.mediaPlayer.currentAudioTrackIndex = id.int32Value
                })
            }
        }
        let subNames = mediaPlayer.videoSubTitlesNames as? [String] ?? []
        let subIDs = mediaPlayer.videoSubTitlesIndexes as? [NSNumber] ?? []
        for (name, id) in zip(subNames, subIDs) {
            let label = id.int32Value < 0 ? "关闭字幕" : "字幕：" + name
            sheet.addAction(UIAlertAction(title: (mediaPlayer.currentVideoSubTitleIndex == id.int32Value ? "✓ " : "") + label, style: .default) { [weak self] _ in
                self?.mediaPlayer.currentVideoSubTitleIndex = id.int32Value
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    // MARK: HUD

    private func buildHUD() {
        hud.showsProgress = true
        hud.titleLabel.text = titleText
        view.addSubview(hud)
        updateHUDTime()
    }

    private func showHUD(message: String? = nil) {
        hud.titleLabel.text = message.map { "\(titleText) · \($0)" } ?? titleText
        updateHUDTime()
        hud.show(autoHide: nil)
        hideHUD?.cancel()
        hideHUD = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Stays up while paused, so the position is always visible.
            guard !Task.isCancelled, let self, self.mediaPlayer.isPlaying else { return }
            self.hud.hide()
        }
    }

    private func updateHUDTime() {
        let now = Double(mediaPlayer.time.intValue) / 1000
        let length = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000
        hud.bodyLabel.text = "\(mediaPlayer.isPlaying ? "▶︎" : "❚❚")  \(BiliText.formatDuration(Int(now))) / \(length > 0 ? BiliText.formatDuration(Int(length)) : "--:--")　　左/右：快退、快进 10 秒　　向下：选项"
        hud.progress.progress = length > 0 ? Float(now / length) : 0
        hud.layout(in: view.bounds, placement: .bottom)
    }

    // MARK: Teardown

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { teardown() }
    }

    func teardown() {
        guard !tornDown else { return }
        saveProgress()
        tornDown = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        hideHUD?.cancel()
        mediaPlayer.delegate = nil
        mediaPlayer.audio?.isMuted = true
        let player = mediaPlayer
        // VLC's stop() blocks on network media.
        DispatchQueue.global(qos: .userInitiated).async {
            player.stop()
            player.media = nil
        }
    }
}

private final class LocalLinkProxy: NSObject {
    weak var controller: LocalFilePlayerViewController?
    init(_ controller: LocalFilePlayerViewController) { self.controller = controller }
    @MainActor @objc func tick(_ link: CADisplayLink) { controller?.tick(link) }
}
