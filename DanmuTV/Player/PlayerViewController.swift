import AVKit
import BiliKit
import UIKit
import SwiftUI
import VideoToolbox

/// Native player. DASH streams are converted to HLS on the fly (DashResourceLoader) so AVPlayer
/// can switch quality by bandwidth; videos without DASH fall back to a progressive MP4.
final class PlayerViewController: AVPlayerViewController, PlayerTeardown {
    private enum StartPosition {
        /// From the account's history (继续播放 rules).
        case resume
        /// Wherever the current item is when the new one attaches (quality switch, recovery).
        case current
        case at(Double)
    }

    private var request: PlayRequest
    private var loadTask: Task<Void, Never>?
    /// Strongly held for the item it serves (AVAssetResourceLoader keeps its delegate weakly).
    private var loader: DashResourceLoader?
    private var playInfo: PlayInfo?
    /// nil = adaptive (自动).
    private var manualQuality: Int?
    /// Set after a decode failure on HEVC/AV1: retry this page with AVC.
    private var forceAVC = false
    /// Set after an HDR/DV variant failed: retry this page in SDR (HDR 播放失败时自动降级).
    private var hdrFailed = false
    /// Set after Dolby/FLAC audio failed: retry with AAC.
    private var audioFailed = false
    private var showsDebug = false
    private var debugTimer: Timer?
    private var errorLogObserver: NSObjectProtocol?
    /// The display manager the criteria were set on, so they can be cleared even after the window is gone.
    private weak var displayManager: AVDisplayManager?
    private var recoveryAttempts = 0
    private var timeObserver: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var lastReportedSecond = -1
    private var finishedReported = false
    /// True while the next page's item is loading (the old item is still attached).
    private var isSwitchingPage = false
    /// What the attached item plays: a switch that fails goes back to it, so progress isn't saved under the page
    /// (or video) that never loaded.
    private var attachedRequest: PlayRequest?
    /// The story position of the attached item (a story module that fails to load goes back to it too).
    private var attachedStory: StorySession?
    private let overlay = PlayerOverlayView()
    /// 高能进度条 above the scrubber (shown with the transport bar), and its busiest moments as markers.
    private let heatBar = HeatBarView()
    private var heatMarkers: [AVTimedMetadataGroup] = []
    /// 互动视频: the story being played (nil for ordinary videos), and whether a module ended waiting for a choice.
    private var story: StorySession?
    private var storyTask: Task<Void, Never>?
    private var awaitingStoryChoice = false
    private var subtitles: [API.Subtitle] = []
    private var selectedSubtitle: API.Subtitle?
    private var subtitleTask: Task<Void, Never>?
    /// 单集循环 (this session only).
    private var loopEnabled = false
    /// 镜像 (this session only; video layer only, never the danmaku).
    private var mirrored = false
    /// cid whose danmaku/subtitles/chapters are loaded; quality switches and recovery keep them.
    private var extrasCID = 0
    private var chapterGroups: [AVTimedMetadataGroup] = []
    private var appliedRuleCount = -1
    private var menuSignature = ""
    /// OP/ED of the current page and which ones were already auto-skipped.
    private var skips: [SkipRange] = []
    private var skipped: Set<SkipRange> = []
    /// Sponsor segments and the page they belong to (kept across quality switches of that page).
    private var sponsorSkips: (cid: Int, ranges: [SkipRange]) = (0, [])
    private var actionsModel: VideoActions?
    private var pendingSkip: SkipRange?
    /// 播完自动播放相关推荐: what follows when this video (its last part) ends.
    private var relatedNext: VideoItem?
    /// Videos played in this player, so related autoplay never loops back.
    private var playedVideos: Set<String> = []
    private var relatedTask: Task<Void, Never>?
    /// 长按确认键临时倍速: the rate to go back to when the button is released.
    private var boostedFrom: Float?
    /// Reports playing / paused / buffering to a phone that cast here.
    private var rateObservation: NSKeyValueObservation?
    #if DEBUG
    private lazy var initialPageIndex = request.pageIndex
    private var debugStartAtUsed = false
    /// UI tests read the player's state here (AVKit's controls aren't all exposed): a tiny separate view, so
    /// the overlay's own subviews stay visible to accessibility.
    private let testMarker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var lastBoost: Float = 0
    #endif

    private static let reportInterval = 15
    private static let upNextLeadTime: Double = 10
    private static let maxRecoveryAttempts = 2

    init(request: PlayRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        appliesPreferredDisplayCriteriaAutomatically = false
        allowsPictureInPicturePlayback = true
        Log.player.info("picture in picture supported: \(AVPictureInPictureController.isPictureInPictureSupported())")
        #if DEBUG
        _ = initialPageIndex
        #endif
        // The TV button backgrounds the app without dismissing the player: save progress then.
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reportProgress()
                // In picture in picture it keeps playing over the other app.
                if !PictureInPicture.keeps(self) { self.player?.pause() }
            }
        }
        overlay.frame = contentOverlayView?.bounds ?? view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.danmakuEnabled = AppSettings.shared.danmakuEnabled
        overlay.danmakuArea = AppSettings.shared.danmakuArea
        overlay.maskEnabled = AppSettings.shared.danmakuMask
        overlay.onMaskFailure = { [weak self] in self?.updateMenus() }
        // The picture, aspect-fit (AVKit's default gravity) inside the overlay.
        overlay.videoRect = { [weak self] in
            guard let self, let size = self.player?.currentItem?.presentationSize, size.width > 0, size.height > 0 else { return .zero }
            return AVMakeRect(aspectRatio: size, insideRect: self.overlay.bounds)
        }
        overlay.timeSource = { [weak self] in
            guard let self, let player = self.player, player.currentItem?.status == .readyToPlay, !self.isSwitchingPage else { return nil }
            return (player.currentTime().seconds, Double(player.rate))
        }
        contentOverlayView?.addSubview(overlay)
        // Above AVKit's controls (it only draws while they're up), so the transport bar's shade doesn't dim it.
        heatBar.alpha = 0
        view.addSubview(heatBar)
        delegate = self
        #if DEBUG
        testMarker.isAccessibilityElement = true
        testMarker.accessibilityIdentifier = "player.state"
        view.addSubview(testMarker)
        #endif
        speeds = [0.5, 0.75, 1, 1.25, 1.5, 2].map { AVPlaybackSpeed(rate: $0, localizedName: String(format: "%gx", $0)) }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdChanged(_:)))
        hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        hold.minimumPressDuration = 0.5
        view.addGestureRecognizer(hold)
        CastReceiver.shared.player = self
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugPanel") { setDebug(true) }
        #endif
        startLoading(.resume)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMirror()
        heatBar.frame = Self.heatBarFrame(in: view.bounds)
    }

    /// Just above the system scrubber, matching its length (tvOS 26 transport bar, measured at 1920×1080).
    static func heatBarFrame(in bounds: CGRect) -> CGRect {
        let scale = bounds.width / 1920
        return CGRect(x: 84 * scale, y: bounds.height - 214 * scale, width: bounds.width - 168 * scale, height: 36 * scale)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back from 画中画: the TV's output mode was handed back when the player left the screen.
        if playInfo != nil { applyDisplayPlan() }
        if awaitingStoryChoice { showStoryChoices() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // While the window still exists: hand the TV's output mode back to the system.
        if isBeingDismissed { resetDisplayMode() }
    }

    private func resetDisplayMode() {
        (displayManager ?? view.window?.avDisplayManager)?.preferredDisplayCriteria = nil
        appliesPreferredDisplayCriteriaAutomatically = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil, !PictureInPicture.keeps(self) else { return }
        teardown()
    }

    private var tornDown = false

    /// Releases everything (idempotent): also called when another player replaces this one.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        debugTimer?.invalidate()
        debugTimer = nil
        loadTask?.cancel()
        subtitleTask?.cancel()
        relatedTask?.cancel()
        storyTask?.cancel()
        reportProgress()
        teardownItem()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        if CastReceiver.shared.player === self {
            // Replaced by another player (a new cast): the phone sees loading, then the new one playing.
            CastReceiver.shared.playerStateChanged(PlayerLauncher.isReplacingPlayer ? .loading : .stopped)
            CastReceiver.shared.player = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader = nil
        resetDisplayMode()
        // Detail pages refresh their 继续播放 state.
        NotificationCenter.default.post(name: .playerDismissed, object: nil)
    }

    // MARK: Loading

    private func startLoading(_ start: StartPosition) {
        loadTask?.cancel()
        // A reload (quality, codec) while the next page is loading: "where it is now" is the old page's time.
        var start = start
        if isSwitchingPage, case .current = start { start = .resume }
        loadTask = Task { [weak self] in await self?.load(start) }
    }

    private func load(_ start: StartPosition) async {
        do {
            var info = try await fetchPlayInfo()
            try Task.checkCancellation()
            if request.resumeLastPage, !request.isPGC {
                request.resumeLastPage = false
                let lastCID = request.pages.count > 1 && AppSettings.shared.resumePlayback
                    ? ((try? await API.playerInfo(bvid: request.bvid, cid: request.cid))?["last_play_cid"].intValue ?? 0) : 0
                try Task.checkCancellation()
                if let page = PlaybackPolicy.resumePage(lastPlayCID: lastCID, pages: request.pages, current: request.pageIndex) {
                    Log.player.info("resuming at page \(page + 1) from history")
                    request.pageIndex = page
                    info = try await fetchPlayInfo()
                    try Task.checkCancellation()
                }
            }
            if request.isChargeOnly, info.isPreview {
                showChargeNotice()
                return
            }
            if request.isPGC, info.isPreview {
                // Never bypassed: the account only gets the free preview of 大会员 episodes.
                showAlert(title: "大会员专享", message: "本集需要大会员，当前仅可试看片段。", dismissesPlayer: false)
            }
            let (item, newLoader) = try await makeItem(info)
            try Task.checkCancellation()

            var position: Double?
            switch start {
            case .resume where request.startAt != nil:
                position = request.startAt
                request.startAt = nil
                request.pgcResume = nil
            case .resume:
                if request.isPGC {
                    let resume = request.pgcResume
                    request.pgcResume = nil
                    position = resume.flatMap { r in
                        r.epID == request.epID
                            ? PlaybackPolicy.resumePosition(lastPlayTime: r.time, lastPlayCID: 0, cid: request.cid,
                                                            duration: info.duration, enabled: AppSettings.shared.resumePlayback)
                            : nil
                    }
                } else {
                    position = PlaybackPolicy.resumePosition(lastPlayTime: info.lastPlayTime, lastPlayCID: info.lastPlayCID, cid: request.cid,
                                                             duration: info.duration, enabled: AppSettings.shared.resumePlayback)
                }
                Log.player.info("history: cid \(info.lastPlayCID) at \(info.lastPlayTime)s → start \(position ?? 0)s")
                #if DEBUG
                // `-startAt <seconds>` lets simulator runs jump near the end to test continuous play.
                if request.pageIndex == initialPageIndex, !debugStartAtUsed, UserDefaults.standard.double(forKey: "startAt") > 0 {
                    position = UserDefaults.standard.double(forKey: "startAt")
                    debugStartAtUsed = true
                }
                #endif
            case .current:
                // Read just before swapping items so a slow playurl round-trip doesn't rewind playback.
                position = player?.currentTime().seconds
            case let .at(seconds):
                position = seconds
            }

            playInfo = info
            skips = (info.skips.isEmpty ? request.current.skips : info.skips)
                + (sponsorSkips.cid == request.cid ? sponsorSkips.ranges : [])
            skipped = []
            attach(item, loader: newLoader)
            applyDisplayPlan()
            applySkipMarkers(to: item)
            if extrasCID != request.cid {
                extrasCID = request.cid
                loadPageExtras(item: item)
                updateInfoPanel()
            } else {
                // Same page, new item (quality switch / recovery): keep danmaku and subtitles as they are.
                applySkipMarkers(to: item)
            }
            if let position, position.isFinite, position > 0 {
                let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                await player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
                try Task.checkCancellation()
            }
            player?.play()
            updateMenus()
            if let artwork = await artworkItem() {
                try Task.checkCancellation()
                item.externalMetadata.append(artwork)
            }
        } catch {
            guard !BiliClient.isCancellation(error), !Task.isCancelled else { return }
            // A failed page / module switch, as opposed to a quality change or recovery of the item still playing.
            let wasSwitching = isSwitchingPage
            isSwitchingPage = false
            if request.isChargeOnly, case BiliError.api = error {
                showChargeNotice()
            } else if case BiliError.api(-10403, _) = error {
                showAlert(title: "地区限制", message: "该内容在你当前所在的地区不可观看（港澳台或海外版权限制）。")
            } else {
                showAlert(title: "无法播放", message: error.localizedDescription)
            }
            if let item = player?.currentItem, let attachedRequest { rollBack(to: attachedRequest, item: item, wasSwitching: wasSwitching) }
        }
    }

    private func fetchPlayInfo() async throws -> PlayInfo {
        request.isPGC
            ? try await API.pgcPlayInfo(epID: request.epID, cid: request.cid)
            : try await API.playInfo(bvid: request.bvid, cid: request.cid)
    }

    private func makeItem(_ info: PlayInfo) async throws -> (AVPlayerItem, DashResourceLoader?) {
        let headers = ["AVURLAssetHTTPHeaderFieldsKey": BiliClient.mediaHeaders]
        if info.hasDash, let selection = StreamSelector.select(info, preferences()) {
            let loader = DashResourceLoader(selection: selection, policy: AppSettings.shared.cdnPolicy,
                                            fastLoad: AppSettings.shared.fastLoad)
            let asset = AVURLAsset(url: DashResourceLoader.masterURL, options: headers)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            // HDR/DV attributes come from the files' init segments (a few KB each).
            await loader.session.prepare()
            Log.player.info("DASH \(selection.videos.map(\.id), privacy: .public) codec \(selection.videos[0].codecs, privacy: .public), \(loader.session.mirrors) mirror(s)")
            return (makeItem(asset), loader)
        }
        // No DASH (old uploads) or nothing the device can decode: single-file MP4.
        guard !request.isPGC else { throw BiliError.api(code: -1, message: "该剧集暂不支持在 Apple TV 上播放") }
        let stream = try await API.progressiveStream(bvid: request.bvid, cid: request.cid)
        Log.player.info("progressive \(stream.qualityName, privacy: .public)")
        return (makeItem(AVURLAsset(url: stream.url, options: headers)), nil)
    }

    private func makeItem(_ asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = [
            Self.metadataItem(.commonIdentifierTitle, request.displayTitle as NSString),
            Self.metadataItem(.iTunesMetadataTrackSubTitle, (request.entries.count > 1 || request.isPGC ? request.title : request.ownerName) as NSString),
        ]
        return item
    }

    /// HDR only when the device/display path can show it and SDR isn't forced.
    private var hdrAllowed: Bool {
        !hdrFailed && !AppSettings.shared.forceSDR && AVPlayer.eligibleForHDRPlayback
    }

    private func preferences() -> StreamPreferences {
        let settings = AppSettings.shared
        var supported: Set<Int> = [CodecPreference.avc.codecID]
        if !forceAVC {
            if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { supported.insert(CodecPreference.hevc.codecID) }
            if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { supported.insert(CodecPreference.av1.codecID) }
        }
        return StreamPreferences(preferredCodec: settings.codecPreference.codecID,
                                 supportedCodecs: supported,
                                 maxQuality: settings.maxQuality,
                                 onlyHighest: settings.onlyHighestQuality,
                                 filterHighFramerate: settings.filterHighFramerate,
                                 allowHDR: hdrAllowed && settings.enableHDR,
                                 allowDolbyVision: hdrAllowed && settings.enableDolbyVision && AVPlayer.availableHDRModes.contains(.dolbyVision),
                                 preferDolbyAudio: settings.enableDolbyAudio && !audioFailed,
                                 preferLosslessAudio: settings.enableLosslessAudio && !audioFailed,
                                 manualQuality: manualQuality)
    }

    private func attach(_ item: AVPlayerItem, loader newLoader: DashResourceLoader?) {
        teardownItem()
        loader = newLoader
        isSwitchingPage = false
        attachedRequest = request
        attachedStory = story
        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            // defaultRate is what play() resumes at, so pausing never resets the chosen speed.
            player.defaultRate = Float(AppSettings.shared.defaultSpeed)
            #if DEBUG
            // Automated simulator runs (scripts/sim.sh) pass `-muted YES`.
            player.isMuted = UserDefaults.standard.bool(forKey: "muted")
            #endif
            self.player = player
            if let speed = speeds.first(where: { abs(Double($0.rate) - AppSettings.shared.defaultSpeed) < 0.01 }) {
                selectSpeed(speed)
            }
            rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self, CastReceiver.shared.player === self else { return }
                    switch player.timeControlStatus {
                    case .playing: CastReceiver.shared.playerStateChanged(.playing)
                    case .paused:
                        // At the end of the item the pause is the end (ended was already sent).
                        let item = player.currentItem
                        let atEnd = item.map { $0.duration.isNumeric && $0.currentTime().seconds >= $0.duration.seconds - 0.5 } ?? false
                        guard !atEnd else { return }
                        CastReceiver.shared.playerStateChanged(self.isSwitchingPage ? .loading : .paused)
                    default: CastReceiver.shared.playerStateChanged(.loading)
                    }
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
        }
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .failed: self?.playbackFailed(item)
                    // AVKit may rebuild its player layer for a new item: re-apply the mirror.
                    case .readyToPlay: self?.applyMirror()
                    default: break
                    }
                }
            },
        ]
        applyMirror()
        errorLogObserver.map { NotificationCenter.default.removeObserver($0) }
        // Segment fetches bypass our code: watch AVPlayer's error log for TLS failures (屏蔽证书异常的 CDN).
        errorLogObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { notification in
            guard let event = (notification.object as? AVPlayerItem)?.errorLog()?.events.last,
                  CDNHealth.isCertificateError(domain: event.errorDomain, code: event.errorStatusCode),
                  let host = event.uri.flatMap({ URL(string: $0)?.host }), host != "play"
            else { return }
            CDNHealth.shared.markBad(host)
            Log.player.error("certificate error from \(host, privacy: .public); blocked for this session")
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinishPage() }
        }
    }

    private func teardownItem() {
        itemObservations = []
        if let errorLogObserver { NotificationCenter.default.removeObserver(errorLogObserver) }
        errorLogObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// Hold the clickpad to play faster (2×, or 3× when already at 2×); release to return to the chosen speed.
    @objc private func holdChanged(_ gesture: UILongPressGestureRecognizer) {
        guard let player else { return }
        switch gesture.state {
        case .began:
            guard boostedFrom == nil, player.timeControlStatus == .playing else { return }
            boostedFrom = player.rate
            let boost: Float = player.rate < 2 ? 2 : 3
            player.rate = boost
            #if DEBUG
            lastBoost = boost
            updateTestMarker()
            #endif
            Log.player.info("hold: \(self.boostedFrom ?? 0)× → \(boost)×")
            overlay.setBoost("▶▶ \(String(format: "%g", boost))× 快进中")
        case .ended, .cancelled, .failed:
            guard let from = boostedFrom else { return }
            boostedFrom = nil
            if player.rate > 0 { player.rate = from }
            Log.player.info("hold released: back to \(from)×, rate now \(player.rate)")
            overlay.setBoost(nil)
            #if DEBUG
            updateTestMarker()
            #endif
        default:
            break
        }
    }

    // MARK: Progress, up next, continuous play

    #if DEBUG
    private func updateTestMarker() {
        let status = player.map { ["paused", "waiting", "playing"][min(2, $0.timeControlStatus.rawValue)] } ?? "none"
        let seconds = player?.currentTime().seconds ?? 0
        let position = seconds.isFinite ? Int(seconds) : 0
        testMarker.accessibilityValue = "bvid=\(request.bvid);rate=\(player?.rate ?? 0);status=\(status);boost=\(lastBoost);pos=\(position);cid=\(request.cid);id=\(ObjectIdentifier(self).hashValue);mask=\(overlay.appliedMaskTime);dur=\(Int(playInfo?.duration ?? 0));story=\(story?.edge.edgeID ?? -1);depth=\(story?.history.count ?? 0)"
    }
    #endif

    private func tick(_ seconds: Double) {
        #if DEBUG
        updateTestMarker()
        #endif
        guard seconds.isFinite, let item = player?.currentItem, !isSwitchingPage else { return }
        if CastReceiver.shared.player === self {
            CastReceiver.shared.playerProgress(position: seconds, duration: item.duration.seconds)
        }
        if PlaybackPolicy.shouldReport(second: Int(seconds), lastReported: lastReportedSecond, interval: Self.reportInterval,
                                       isPlaying: player?.timeControlStatus == .playing)
        {
            reportProgress()
        }
        handleSkips(at: seconds)
        let autoPlay = request.hasNextPage ? AppSettings.shared.autoPlayNext : AppSettings.shared.autoPlayRelated
        let upNext = !loopEnabled && PlaybackPolicy.isUpNext(position: seconds, duration: item.duration.seconds,
                                                             hasNext: request.hasNextPage || relatedNext != nil,
                                                             autoPlay: autoPlay, leadTime: Self.upNextLeadTime)
        updateContextualActions(upNext: upNext, skip: pendingSkip)
    }

    /// Saves the position to the account's history. After the page finished, the full duration was
    /// reported; later calls for the same page are skipped so they can't overwrite it.
    private func reportProgress(finished: Bool = false) {
        guard let player, request.aid > 0, BiliClient.shared.currentAccount != nil, !finishedReported, !isSwitchingPage else { return }
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        let seconds = Int(finished && duration.isFinite ? duration : (current.isFinite ? current : 0))
        guard seconds > 0 else { return }
        lastReportedSecond = seconds
        finishedReported = finished
        let (aid, cid, epID, seasonID, seasonType) = (request.aid, request.cid, request.epID, request.seasonID, request.seasonType)
        Task.detached {
            do {
                if seasonID > 0 {
                    try await API.reportPGCProgress(aid: aid, cid: cid, epID: epID, seasonID: seasonID, seasonType: seasonType, seconds: seconds)
                } else {
                    try await API.reportProgress(aid: aid, cid: cid, seconds: seconds)
                }
                Log.player.info("reported \(seconds)s for av\(aid) cid \(cid)")
            } catch {
                Log.player.error("history report failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func didFinishPage() {
        if loopEnabled {
            skipped = []
            player?.seek(to: .zero)
            player?.play()
            return
        }
        reportProgress(finished: true)
        if CastReceiver.shared.player === self { CastReceiver.shared.playerStateChanged(.ended) }
        if story != nil {
            showStoryChoices()
            return
        }
        if request.hasNextPage {
            if AppSettings.shared.autoPlayNext { playPage(request.pageIndex + 1) }
        } else if let next = relatedNext, AppSettings.shared.autoPlayRelated {
            playRelated(next)
        }
    }

    private func playPage(_ index: Int) {
        guard request.entries.indices.contains(index) else { return }
        Log.player.info("switching to page \(index + 1)/\(self.request.entries.count)")
        reportProgress()
        request.pageIndex = index
        beginSwitch()
        startLoading(.resume)
    }

    /// Plays a related video in this player when the current one ends (or from the 即将播放 button).
    private func playRelated(_ item: VideoItem) {
        guard !isSwitchingPage else { return }
        Log.player.info("autoplay related \(item.bvid, privacy: .public)")
        reportProgress()
        beginSwitch()
        relatedNext = nil
        relatedTask?.cancel()
        relatedTask = Task { [weak self] in
            let detail = try? await API.videoDetail(bvid: item.bvid)
            guard let self, !Task.isCancelled else { return }
            // Missing, or a 番剧 episode (needs the season flow): stop here as if nothing followed.
            guard let detail, detail.redirectEpID == 0, !detail.pages.isEmpty else {
                self.isSwitchingPage = false
                self.overlay.showToast("无法播放：\(item.title)")
                // Chosen from 即将播放 before the end: carry on with this one (no-op once it has ended).
                self.player?.play()
                return
            }
            self.request = PlayRequest(detail: detail, pageIndex: 0, resumeLastPage: true)
            self.sponsorSkips = (0, [])
            self.endStory()
            self.startLoading(.resume)
        }
    }

    /// A switch that failed: back to what the attached item plays, with what `beginSwitch` cleared for it.
    private func rollBack(to attached: PlayRequest, item: AVPlayerItem, wasSwitching: Bool) {
        request = attached
        // Only when it was leaving a module: a failed quality change mid-module mustn't offer the choices early.
        if wasSwitching, story != nil || attachedStory != nil {
            story = attachedStory
            // The old module has ended (that's why it switched): its choices again.
            awaitingStoryChoice = story != nil
            updateContextualActions(upNext: false)
        }
        if extrasCID != request.cid {
            extrasCID = request.cid
            loadPageExtras(item: item)
            applySkipMarkers(to: item)
        }
    }

    /// State that belongs to the page being left.
    private func beginSwitch() {
        // The next page has its own 高能时刻 (the current item is re-marked before its extras load).
        heatMarkers = []
        heatBar.set(nil, duration: 0)
        boostedFrom = nil
        overlay.setBoost(nil)
        extrasCID = 0
        lastReportedSecond = -1
        finishedReported = false
        recoveryAttempts = 0
        forceAVC = false
        hdrFailed = false
        audioFailed = false
        isSwitchingPage = true
        updateContextualActions(upNext: false)
        player?.pause()
    }

    /// Buttons over the video: 跳过片头/片尾 while inside an OP/ED (when not auto-skipping), and the
    /// one-press 下一P/下一集 button, which becomes the 即将播放 prompt near the end.
    private func updateContextualActions(upNext: Bool, skip: SkipRange? = nil) {
        var actions: [UIAction] = []
        if awaitingStoryChoice {
            actions.append(UIAction(title: "选择剧情", image: UIImage(systemName: "arrow.triangle.branch")) { [weak self] _ in
                self?.showStoryChoices()
            })
        }
        if let skip {
            actions.append(UIAction(title: Self.skipLabel(skip.kind, past: false), image: UIImage(systemName: "forward.fill")) { [weak self] _ in
                self?.skipped.insert(skip)
                self?.player?.seek(to: CMTime(seconds: skip.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            })
        }
        if request.hasNextPage, !isSwitchingPage {
            let next = request.entries[request.pageIndex + 1]
            let label = request.isPGC ? "下一集 " : "下一P "
            actions.append(UIAction(title: (upNext ? "即将播放 " : label) + next.title, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                guard let self else { return }
                self.playPage(self.request.pageIndex + 1)
            })
        } else if upNext, let next = relatedNext, !isSwitchingPage, story == nil {
            // Only near the end: a permanent button for an unrelated video would be noise.
            actions.append(UIAction(title: "即将播放 " + next.title, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                self?.playRelated(next)
            })
        }
        guard actions.map(\.title) != contextualActions.map(\.title) else { return }
        contextualActions = actions
    }

    static func skipLabel(_ kind: SkipRange.Kind, past: Bool) -> String {
        switch kind {
        case .opening: return past ? "已跳过片头" : "跳过片头"
        case .ending: return past ? "已跳过片尾" : "跳过片尾"
        case .sponsor: return past ? "已跳过恰饭片段" : "跳过恰饭片段"
        }
    }

    /// Auto-skips each OP/ED (and, when enabled, sponsor segment) once per load; otherwise offers
    /// the skip button while inside one.
    private func handleSkips(at seconds: Double) {
        guard let range = skips.first(where: { seconds >= $0.start && seconds < $0.end - 1 }), !skipped.contains(range) else {
            pendingSkip = nil
            return
        }
        let auto = range.kind == .sponsor ? AppSettings.shared.skipSponsorSegments : AppSettings.shared.autoSkipOPED
        if auto {
            skipped.insert(range)
            Log.player.info("auto-skipping \(Self.skipLabel(range.kind, past: false), privacy: .public) to \(range.end)s")
            player?.seek(to: CMTime(seconds: range.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            overlay.showToast(Self.skipLabel(range.kind, past: true))
        } else {
            pendingSkip = range
        }
    }

    /// OP/ED and chapters on the scrubber as navigation markers. (Interstitial ranges were not used:
    /// AVKit treats them like ads, removing them from the timeline and blocking scrubbing into them.)
    private func applySkipMarkers(to item: AVPlayerItem) {
        var groups: [AVNavigationMarkersGroup] = []
        if !chapterGroups.isEmpty { groups.append(AVNavigationMarkersGroup(title: "章节", timedNavigationMarkers: chapterGroups)) }
        if !heatMarkers.isEmpty { groups.append(AVNavigationMarkersGroup(title: "高能时刻", timedNavigationMarkers: heatMarkers)) }
        func markers(_ kinds: Set<SkipRange.Kind>) -> [AVTimedMetadataGroup] {
            skips.filter { kinds.contains($0.kind) }.map { r in
                let title = r.kind == .opening ? "片头" : r.kind == .ending ? "片尾" : "恰饭片段"
                return AVTimedMetadataGroup(items: [Self.metadataItem(.commonIdentifierTitle, title as NSString)],
                                            timeRange: CMTimeRange(start: CMTime(seconds: r.start, preferredTimescale: 600),
                                                                   end: CMTime(seconds: r.end, preferredTimescale: 600)))
            }
        }
        let opEd = markers([.opening, .ending])
        if !opEd.isEmpty { groups.append(AVNavigationMarkersGroup(title: "片头/片尾", timedNavigationMarkers: opEd)) }
        let sponsor = markers([.sponsor])
        if !sponsor.isEmpty { groups.append(AVNavigationMarkersGroup(title: "广告", timedNavigationMarkers: sponsor)) }
        item.navigationMarkerGroups = groups
    }

    // MARK: Display matching

    /// 匹配动态范围和帧率: automatic from the stream, or explicit criteria for a fixed output
    /// rate / forced SDR; or leave the TV alone.
    private func applyDisplayPlan() {
        let settings = AppSettings.shared
        let top = loader?.selection.videos.first
        let range = loader.map { $0.session.attributes(variant: 0).range } ?? "SDR"
        let isDV = loader.map { $0.session.isDolbyVision(variant: 0) } ?? false
        let plan = DisplayPlan.make(mode: settings.displayMatchMode, contentRange: range,
                                    contentFrameRate: top?.frameRate ?? 0, forcedRefreshRate: settings.forcedRefreshRate,
                                    forceSDR: settings.forceSDR)
        appliesPreferredDisplayCriteriaAutomatically = plan.automatic
        guard let manager = view.window?.avDisplayManager else { return }
        displayManager = manager
        if let rate = plan.manualRefreshRate,
           let criteria = Self.displayCriteria(refreshRate: rate, range: plan.manualRange, dolbyVision: isDV && plan.manualRange != "SDR")
        {
            manager.preferredDisplayCriteria = criteria
        } else if !plan.automatic {
            manager.preferredDisplayCriteria = nil
        }
        Log.player.info("display plan: auto=\(plan.automatic) rate=\(plan.manualRefreshRate ?? 0) range=\(plan.manualRange, privacy: .public)")
    }

    private static func displayCriteria(refreshRate: Double, range: String, dolbyVision: Bool) -> AVDisplayCriteria? {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: range == "SDR" ? kCMFormatDescriptionColorPrimaries_ITU_R_709_2 : kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_YCbCrMatrix: range == "SDR" ? kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 : kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        switch range {
        case "PQ": extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case "HLG": extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        var description: CMVideoFormatDescription?
        // A DV format description puts the TV in Dolby Vision mode rather than HDR10.
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: dolbyVision ? kCMVideoCodecType_DolbyVisionHEVC : kCMVideoCodecType_HEVC,
                                       width: 3840, height: 2160,
                                       extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard let description else { return nil }
        return AVDisplayCriteria(refreshRate: Float(refreshRate), formatDescription: description)
    }

    // MARK: Debug panel

    static func variantAndMirror(_ uri: String?) -> (variant: Int, mirror: Int)? {
        guard let name = uri.flatMap({ URL(string: $0)?.deletingPathExtension().lastPathComponent }), name.hasPrefix("v"),
              let m = name.firstIndex(of: "m"), let v = Int(name[name.index(after: name.startIndex) ..< m]),
              let mirror = Int(name[name.index(after: m)...])
        else { return nil }
        return (v, mirror)
    }

    private func setDebug(_ on: Bool) {
        showsDebug = on
        debugTimer?.invalidate()
        debugTimer = nil
        if on {
            // Its own timer: keeps updating while paused or stalled (exactly when it's needed).
            debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDebugPanel() }
            }
            updateDebugPanel()
        } else {
            overlay.setDebugText(nil)
        }
    }

    private func updateDebugPanel() {
        guard showsDebug, let item = player?.currentItem else { return }
        var lines: [String] = []
        let size = item.presentationSize
        // The access log names the variant playlist being played: bilihls://play/v{i}m{m}.m3u8.
        let current = Self.variantAndMirror(item.accessLog()?.events.last?.uri)
        let playingIndex = current?.variant
            ?? loader?.selection.videos.indices.min { i, j in
                let vs = loader!.selection.videos
                return abs(Double(vs[i].height) - size.height) < abs(Double(vs[j].height) - size.height)
            }
        let playing = playingIndex.flatMap { i in loader?.selection.videos.indices.contains(i) == true ? loader?.selection.videos[i] : nil }
        if let v = playing, let info = playInfo, let i = playingIndex {
            let hls = loader?.session.attributes(variant: i) ?? v.hlsVideo
            lines.append("视频  \(info.qualityName(v.id))  \(Int(size.width))×\(Int(size.height))  \(hls.codecs)  \(hls.range)  \(String(format: "%.2f", v.frameRate))fps")
        } else {
            lines.append("视频  \(Int(size.width))×\(Int(size.height))  （单文件 MP4）")
        }
        if let a = loader?.selection.audio {
            lines.append("音频  \(a.codecs)  \(a.bandwidth / 1000) kbps\(loader?.selection.audioIsAtmos == true ? "  Atmos" : "")")
        }
        if let event = item.accessLog()?.events.last {
            lines.append(String(format: "码率  当前档 %.1f Mbps · 实测网速 %.1f Mbps · 平均 %.1f Mbps",
                                event.indicatedBitrate / 1e6, event.observedBitrate / 1e6, event.averageVideoBitrate / 1e6))
            lines.append("丢帧 \(event.numberOfDroppedVideoFrames) · 卡顿 \(event.numberOfStalls)")
        }
        if let i = playingIndex, let url = loader?.session.segmentURL(track: "v\(i)", mirror: current?.mirror ?? 0) {
            lines.append("CDN  \(URL(string: url)?.host ?? "?")\(CDN.isPCDN(url) ? "（PCDN）" : "")  线路 \((current?.mirror ?? 0) + 1)/\(loader?.session.mirrors ?? 1)")
            lines.append("URL  " + String(url.prefix(160)))
        }
        if let hosts = loader?.session.hosts, !hosts.isEmpty {
            lines.append("索引  " + hosts.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }.joined(separator: "  "))
        }
        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            let ahead = range.end.seconds - (player?.currentTime().seconds ?? 0)
            lines.append(String(format: "缓冲  %.0f 秒", max(0, ahead)))
        }
        let display = view.window?.avDisplayManager
        lines.append("显示  \(appliesPreferredDisplayCriteriaAutomatically ? "自动匹配" : "固定")\(display?.isDisplayCriteriaMatchingEnabled == true ? "" : "（系统未开启匹配）")\(display?.isDisplayModeSwitchInProgress == true ? " · 切换中" : "")")
        lines.append(DeviceStats.summary())
        overlay.setDebugText(lines.joined(separator: "\n"))
    }

    // MARK: Menus

    private func updateMenus() {
        guard let info = playInfo else { return }
        // Rebuilding while a menu is open collapses it on tvOS: only rebuild when something changed.
        let signature = [String(describing: manualQuality), String(loader?.selection.videos.map(\.id).description ?? ""),
                         "\(overlay.danmakuEnabled)\(overlay.danmakuArea)\(overlay.hasMask)\(overlay.maskEnabled)", subtitles.map(\.id).joined(),
                         selectedSubtitle?.id ?? "-", "\(loopEnabled)\(mirrored)\(showsDebug)"].joined(separator: "|")
        guard signature != menuSignature else { return }
        menuSignature = signature
        var menus: [UIMenuElement] = [qualityMenu(info), danmakuMenu()]
        if !subtitles.isEmpty { menus.append(subtitleMenu()) }
        menus.append(playbackMenu())
        transportBarCustomMenuItems = menus
    }

    private func qualityMenu(_ info: PlayInfo) -> UIMenu {
        let codec = loader?.selection.videos.first?.codecID
        // Qualities offered in the codec family actually playing, best first.
        let ids = Array(Set(info.videos.filter { codec == nil || $0.codecID == codec }.map(\.id)))
            .filter { !(125 ... 126).contains($0) }
            .sorted(by: >)
        var actions = [UIAction(title: "自动", state: manualQuality == nil ? .on : .off) { [weak self] _ in
            self?.selectQuality(nil)
        }]
        for id in ids {
            actions.append(UIAction(title: info.qualityName(id), state: manualQuality == id ? .on : .off) { [weak self] _ in
                self?.selectQuality(id)
            })
        }
        let playing = loader?.selection.videos
        let subtitle = manualQuality == nil
            ? (playing?.count == 1 ? info.qualityName(playing![0].id) + "（最高）" : "自动")
            : playing.flatMap { $0.first.map { info.qualityName($0.id) } } ?? "自动"
        return UIMenu(title: "画质", subtitle: subtitle, image: UIImage(systemName: "slider.horizontal.3"),
                      options: .singleSelection, children: actions)
    }

    /// 播放器内快速切换弹幕开关和显示区域. Choices here become the default (same as 设置 › 弹幕).
    private func danmakuMenu() -> UIMenu {
        let toggle = UIAction(title: overlay.danmakuEnabled ? "关闭弹幕" : "开启弹幕",
                              image: UIImage(systemName: overlay.danmakuEnabled ? "text.bubble.fill" : "text.bubble")) { [weak self] _ in
            guard let self else { return }
            self.overlay.danmakuEnabled.toggle()
            AppSettings.shared.danmakuEnabled = self.overlay.danmakuEnabled
            self.updateMenus()
        }
        let areas: [(String, Double)] = [("1/4 屏", 0.25), ("半屏", 0.5), ("3/4 屏", 0.75), ("全屏", 1)]
        let area = UIMenu(title: "显示区域", options: .singleSelection, children: areas.map { name, value in
            UIAction(title: name, state: abs(overlay.danmakuArea - value) < 0.01 ? .on : .off) { [weak self] _ in
                self?.overlay.danmakuArea = value
                AppSettings.shared.danmakuArea = value
                self?.updateMenus()
            }
        })
        var children: [UIMenuElement] = [toggle, area]
        if overlay.hasMask {
            children.append(UIAction(title: "智能防挡", image: UIImage(systemName: "person.crop.rectangle"),
                                     state: overlay.maskEnabled ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.overlay.maskEnabled.toggle()
                AppSettings.shared.danmakuMask = self.overlay.maskEnabled
                self.updateMenus()
            })
        }
        return UIMenu(title: "弹幕", subtitle: overlay.danmakuEnabled ? "开" : "关",
                      image: UIImage(systemName: "text.bubble"), children: children)
    }

    private func subtitleMenu() -> UIMenu {
        var actions = [UIAction(title: "关闭", state: selectedSubtitle == nil ? .on : .off) { [weak self] _ in
            self?.selectSubtitle(nil)
        }]
        for sub in subtitles {
            actions.append(UIAction(title: sub.name + (sub.isAI ? "（AI）" : ""), state: selectedSubtitle == sub ? .on : .off) { [weak self] _ in
                self?.selectSubtitle(sub)
            })
        }
        return UIMenu(title: "字幕", subtitle: selectedSubtitle?.name ?? "关闭", image: UIImage(systemName: "captions.bubble"),
                      options: .singleSelection, children: actions)
    }

    private func playbackMenu() -> UIMenu {
        let loop = UIAction(title: "单集循环", image: UIImage(systemName: "repeat.1"), state: loopEnabled ? .on : .off) { [weak self] _ in
            self?.loopEnabled.toggle()
            self?.updateMenus()
        }
        let debug = UIAction(title: "调试信息", image: UIImage(systemName: "ladybug"), state: showsDebug ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.setDebug(!self.showsDebug)
            self.menuSignature = ""
            self.updateMenus()
        }
        let mirror = UIAction(title: "镜像画面", image: UIImage(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right"),
                              state: mirrored ? .on : .off) { [weak self] _ in
            self?.mirrored.toggle()
            self?.applyMirror()
            self?.updateMenus()
        }
        let blockRoute = UIAction(title: "拉黑当前线路并重试", image: UIImage(systemName: "nosign")) { [weak self] _ in
            self?.blacklistCurrentRoute()
        }
        return UIMenu(title: "播放", image: UIImage(systemName: "ellipsis.circle"), children: [loop, mirror, debug, blockRoute])
    }

    /// Flips the video layer only; the danmaku/subtitle overlay is a separate view and stays readable.
    private func applyMirror() {
        guard let layer = Self.findPlayerLayer(in: view.layer) else { return }
        layer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        overlay.videoMirrored = mirrored
    }

    private static func findPlayerLayer(in layer: CALayer) -> AVPlayerLayer? {
        if let playerLayer = layer as? AVPlayerLayer { return playerLayer }
        for sub in layer.sublayers ?? [] {
            if let found = findPlayerLayer(in: sub) { return found }
        }
        return nil
    }

    /// The related video to autoplay after the last part of a UGC video.
    private func loadRelatedNext() {
        relatedNext = nil
        relatedTask?.cancel()
        let bvid = request.bvid
        playedVideos.insert(bvid)
        guard !request.isPGC, !request.hasNextPage, AppSettings.shared.autoPlayRelated, !bvid.isEmpty else { return }
        relatedTask = Task { [weak self] in
            guard let related = try? await API.related(bvid: bvid), let self, !Task.isCancelled, self.request.bvid == bvid else { return }
            self.relatedNext = AutoPlay.next(after: bvid, related: related, played: self.playedVideos)
        }
    }

    /// 向下轻扫唤起视频详情: title and like / coin / favourite / follow without leaving playback.
    private func updateInfoPanel() {
        let actions = request.aid > 0 ? VideoActions(aid: request.aid, bvid: request.bvid, ownerMid: request.ownerMid) : nil
        actionsModel = actions
        let panel = UIHostingController(rootView: PlayerInfoPanel(title: request.displayTitle,
                                                                  subtitle: request.entries.count > 1 || request.isPGC ? request.title : request.ownerName,
                                                                  cover: request.cover, actions: actions)
            .environment(AccountStore.shared)
            .tint(Theme.accent))
        panel.title = "详情"
        panel.preferredContentSize = CGSize(width: 0, height: 300)
        customInfoViewControllers = [panel]
    }

    // MARK: Danmaku, subtitles, chapters

    /// Per-page extras that don't block playback.
    private func loadPageExtras(item: AVPlayerItem) {
        loadRelatedNext()
        overlay.load(cid: request.cid, accountRules: AccountDanmakuRules.cached)
        appliedRuleCount = AccountDanmakuRules.cached.count
        loadHeat()
        chapterGroups = []
        subtitles = []
        selectedSubtitle = nil
        subtitleTask?.cancel()
        let (bvid, cid) = (request.bvid, request.cid)
        // Sponsor segments load on their own so a slow lookup never delays subtitles/chapters.
        if AppSettings.shared.skipSponsorSegments, !request.isPGC {
            let multiPart = request.entries.count > 1
            Task { [weak self] in
                guard let segments = try? await API.sponsorSegments(bvid: bvid, cid: cid, multiPart: multiPart), !segments.isEmpty,
                      let self, self.request.cid == cid else { return }
                self.sponsorSkips = (cid, segments)
                self.skips += segments
                if let current = self.player?.currentItem { self.applySkipMarkers(to: current) }
                Log.player.info("\(segments.count) sponsor segment(s)")
            }
        }
        subtitleTask = Task { [weak self] in
            await AccountDanmakuRules.refreshIfNeeded()
            if let self, self.request.cid == cid, AccountDanmakuRules.cached.count != self.appliedRuleCount {
                self.appliedRuleCount = AccountDanmakuRules.cached.count
                self.overlay.applyAccountRules(AccountDanmakuRules.cached)
            }
            guard let info = try? await API.playerInfo(bvid: bvid, cid: cid), !Task.isCancelled, let self, self.request.cid == cid else { return }
            let chapters = API.chapters(fromPlayerInfo: info)
            self.chapterGroups = chapters.map { chapter in
                AVTimedMetadataGroup(items: [Self.metadataItem(.commonIdentifierTitle, chapter.title as NSString)],
                                     timeRange: CMTimeRange(start: CMTime(seconds: chapter.from, preferredTimescale: 600),
                                                            end: CMTime(seconds: chapter.to, preferredTimescale: 600)))
            }
            if let current = self.player?.currentItem { self.applyChapterGroups(to: current) }
            self.subtitles = API.subtitles(fromPlayerInfo: info)
            if !self.request.isPGC, let version = API.storyGraphVersion(fromPlayerInfo: info) { self.startStory(version: version) }
            if let mask = API.danmakuMask(fromPlayerInfo: info) {
                self.overlay.setMask(mask)
                Log.player.info("danmaku mask available (\(mask.fps) fps)")
            }
            Log.player.info("page extras: \(self.subtitles.map(\.language), privacy: .public) subtitles, \(chapters.count) chapters, \(AccountDanmakuRules.cached.count) block rules")
            let settings = AppSettings.shared
            if settings.showSubtitles {
                // Prefer human subtitles (Chinese first); AI ones only when allowed by default.
                let human = self.subtitles.filter { !$0.isAI }
                let pick = human.first { $0.language.hasPrefix("zh") } ?? human.first
                    ?? (settings.subtitleAIDefault ? self.subtitles.first { $0.language.contains("zh") } ?? self.subtitles.first : nil)
                self.selectSubtitle(pick)
            }
            self.updateMenus()
        }
    }

    // MARK: 互动视频

    /// Loads the story's first module the first time an interactive video plays (later modules come from choices).
    private func startStory(version: Int) {
        guard story?.aid != request.aid || story?.graphVersion != version else { return }
        let (aid, bvid, cid) = (request.aid, request.bvid, request.cid)
        storyTask?.cancel()
        storyTask = Task { [weak self] in
            do {
                let start = try await API.storyEdge(aid: aid, bvid: bvid, graphVersion: version, edgeID: 0)
                guard let self, !Task.isCancelled, self.request.aid == aid else { return }
                self.story = StorySession(aid: aid, bvid: bvid, graphVersion: version, start: start, cid: cid)
                Log.player.info("interactive video: graph \(version), start module \(start.edgeID) with \(start.questions.count) question(s)")
            } catch {
                guard !BiliClient.isCancellation(error) else { return }
                Log.player.error("story graph failed: \(error.localizedDescription, privacy: .public)")
                self?.overlay.showToast("互动剧情加载失败，将按普通视频播放")
            }
        }
    }

    private func endStory() {
        storyTask?.cancel()
        story = nil
        awaitingStoryChoice = false
    }

    /// At the end of a module: the choices (or the ending), or straight on when the story decides by itself.
    private func showStoryChoices() {
        guard let story, !tornDown else { return }
        var edge = story.edge
        var choices: [StoryEdge.Choice] = []
        var preferred: StoryEdge.Choice?
        var timeLimit: Double?
        if let question = edge.questions.first, !edge.isLeaf {
            let automatic = story.state.automaticChoice(question)
            choices = story.state.visibleChoices(question)
            // In the corner (画中画) nobody can press a button: the story goes on by itself.
            if question.type == 0 || choices.isEmpty || PictureInPicture.keeps(self) {
                // No buttons (hidden jumps, conditions): Bilibili's player moves on by itself.
                if let automatic {
                    takeStory(.choice(automatic))
                    return
                }
                // Nothing allowed: treat it as an ending rather than stopping without a word.
                edge.isLeaf = true
                choices = []
            }
            if !choices.isEmpty {
                preferred = automatic.flatMap { choices.contains($0) ? $0 : nil } ?? choices.first
                timeLimit = question.timeLimit
            }
        }
        awaitingStoryChoice = true
        updateContextualActions(upNext: false)
        // Something else on screen, or in the corner: 选择剧情 (and coming back full screen) brings the chooser.
        guard presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        present(StoryChooserController(edge: edge, choices: choices, timeLimit: timeLimit, defaultChoice: preferred,
                                       canGoBack: !story.history.isEmpty) { [weak self] pick in self?.takeStory(pick) },
                animated: true)
    }

    private func takeStory(_ pick: StoryPick) {
        guard var session = story, !tornDown, !isSwitchingPage else { return }
        awaitingStoryChoice = false
        updateContextualActions(upNext: false)
        switch pick {
        case .back:
            guard let step = session.history.popLast() else { return }
            session.edge = step.edge
            session.cid = step.cid
            session.state = step.state
            story = session
            playStoryModule(cid: step.cid, title: step.edge.title)
            return
        case let .choice(choice):
            session.history.append(.init(edge: session.edge, cid: session.cid, state: session.state))
            session.state.choose(choice)
            loadStoryModule(session, edgeID: choice.edgeID, cid: choice.cid)
        case .restart:
            let first = session.history.first ?? .init(edge: session.edge, cid: session.cid, state: session.state)
            loadStoryModule(StorySession(aid: session.aid, bvid: session.bvid, graphVersion: session.graphVersion, start: first.edge, cid: first.cid),
                            edgeID: 0, cid: first.cid)
        }
    }

    /// Fetches the module a choice leads to, then plays it from the start.
    private func loadStoryModule(_ session: StorySession, edgeID: Int, cid: Int) {
        storyTask?.cancel()
        storyTask = Task { [weak self] in
            do {
                let edge = try await API.storyEdge(aid: session.aid, bvid: session.bvid, graphVersion: session.graphVersion, edgeID: edgeID)
                guard let self, !Task.isCancelled else { return }
                var next = session
                if edgeID == 0 {
                    next = StorySession(aid: session.aid, bvid: session.bvid, graphVersion: session.graphVersion, start: edge, cid: cid)
                } else {
                    next.edge = edge
                    next.cid = cid
                    next.state.enter(edge)
                }
                self.story = next
                self.playStoryModule(cid: cid, title: edge.title)
            } catch {
                guard !BiliClient.isCancellation(error), let self else { return }
                Log.player.error("story module \(edgeID) failed: \(error.localizedDescription, privacy: .public)")
                self.overlay.showToast("剧情加载失败，请重试")
                self.awaitingStoryChoice = true
                self.updateContextualActions(upNext: false)
            }
        }
    }

    private func playStoryModule(cid: Int, title: String) {
        guard let story else { return }
        Log.player.info("story → module \(story.edge.edgeID) (cid \(cid))")
        reportProgress()
        request.entries = [PlayRequest.Entry(aid: story.aid, bvid: story.bvid, cid: cid, epID: 0, title: title, isVIP: false, skips: [])]
        request.pageIndex = 0
        beginSwitch()
        if !title.isEmpty { overlay.showToast(title) }
        startLoading(.at(0))
    }

    /// 高能进度条: the curve fills in as danmaku segments arrive; the markers come once the whole video is counted.
    private func loadHeat() {
        heatBar.set(nil, duration: 0)
        heatMarkers = []
        guard AppSettings.shared.heatBar, let duration = playInfo?.duration, duration > 0 else { return }
        let cid = request.cid
        overlay.startHeat(duration: duration) { [weak self] curve, complete in
            guard let self, self.request.cid == cid else { return }
            self.heatBar.set(curve, duration: duration)
            guard complete, let curve else { return }
            let peaks = curve.highlights(count: 3, spacing: max(30, duration / 12), duration: duration)
            self.heatMarkers = peaks.enumerated().map { i, t in
                AVTimedMetadataGroup(items: [Self.metadataItem(.commonIdentifierTitle, "高能 \(i + 1) · \(String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60))" as NSString)],
                                     timeRange: CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600)))
            }
            Log.player.info("heat: \(curve.values.count) samples, highlights at \(peaks.map { Int($0) }, privacy: .public)")
            if let item = self.player?.currentItem { self.applySkipMarkers(to: item) }
        }
    }

    private func selectSubtitle(_ subtitle: API.Subtitle?) {
        selectedSubtitle = subtitle
        overlay.setSubtitles([])
        updateMenus()
        guard let subtitle else { return }
        let cid = request.cid
        Task { [weak self] in
            guard let lines = try? await API.subtitleLines(subtitle), let self, self.request.cid == cid,
                  self.selectedSubtitle == subtitle
            else { return }
            self.overlay.setSubtitles(lines)
            Log.player.info("subtitle \(subtitle.language, privacy: .public): \(lines.count) lines")
        }
    }

    /// UGC chapters as native navigation markers (shown on the scrubber). OP/ED skip ranges
    /// go to `interstitialTimeRanges` instead, so the two don't overwrite each other.
    private func applyChapterGroups(to item: AVPlayerItem) {
        applySkipMarkers(to: item)
    }

    private func selectQuality(_ id: Int?) {
        guard id != manualQuality else { return }
        manualQuality = id
        startLoading(.current)
    }

    /// Adds the host serving the current variant to the blacklist and reloads in place.
    private func blacklistCurrentRoute() {
        let current = Self.variantAndMirror(player?.currentItem?.accessLog()?.events.last?.uri)
        guard let url = loader?.session.segmentURL(track: "v\(current?.variant ?? 0)", mirror: current?.mirror ?? 0),
              let host = URL(string: url)?.host?.lowercased()
        else { return }
        if !AppSettings.shared.cdnBlacklist.contains(host) { AppSettings.shared.cdnBlacklist.append(host) }
        overlay.showToast("已拉黑 \(host)")
        startLoading(.current)
    }

    // MARK: Errors

    /// Shows the concrete reason (HTTP status, CDN host, parse failure…).
    private func playbackFailed(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        let event = item.errorLog()?.events.last
        let httpStatus = event?.errorStatusCode ?? 0
        // Signed CDN URLs expire (~2h) and mirrors die: fetch fresh URLs once and continue in place.
        // A non-HTTP failure on HEVC/AV1 is treated as a decode problem: retry with AVC.
        if recoveryAttempts < Self.maxRecoveryAttempts {
            recoveryAttempts += 1
            let codec = loader?.selection.videos.first?.codecID ?? 7
            let isNetwork = (400 ..< 600).contains(httpStatus) || event?.errorDomain == NSURLErrorDomain
            let failing = Self.variantAndMirror(event?.uri)
            let failedVideo = failing.flatMap { f in loader?.selection.videos.indices.contains(f.variant) == true ? loader?.selection.videos[f.variant] : nil }
            let audioCodecs = loader?.selection.audio.codecs ?? ""
            let audioIsSpecial = audioCodecs.hasPrefix("ec-3") || audioCodecs.lowercased().hasPrefix("flac")
            let uriIsAudio = event?.uri.map { $0.contains("/am") } ?? false
            if !isNetwork {
                if failedVideo?.isHDR == true || (failing == nil && loader?.selection.hasHDR == true && !uriIsAudio) {
                    hdrFailed = true
                    overlay.showToast("HDR 播放失败，已切换为 SDR")
                } else if audioIsSpecial, uriIsAudio || failing == nil {
                    audioFailed = true
                    overlay.showToast("杜比/无损音频播放失败，已切换为 AAC")
                } else if codec != 7 {
                    forceAVC = true
                }
            }
            Log.player.error("item failed (HTTP \(httpStatus), codec \(codec)); recovering, attempt \(self.recoveryAttempts)")
            startLoading(.current)
            return
        }
        var lines = [item.error?.localizedDescription ?? "未知错误"]
        if let event {
            var detail = "错误 \(event.errorStatusCode)"
            if let host = event.uri.flatMap({ URL(string: $0)?.host }) { detail += " · \(host)" }
            if let comment = event.errorComment { detail += " · \(comment)" }
            lines.append(detail)
        }
        if let cdnError = loader?.session.lastError { lines.append(cdnError) }
        Log.player.error("playback failed: \(lines.joined(separator: " | "), privacy: .public)")
        showAlert(title: "播放失败", message: lines.joined(separator: "\n"))
    }

    private func artworkItem() async -> AVMetadataItem? {
        guard let url = BiliText.thumbnail(request.cover, width: 640, height: 360),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        return Self.metadataItem(.commonIdentifierArtwork, data as NSData)
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    private func showChargeNotice() {
        showAlert(title: "充电专属视频", message: "该视频为 UP 主的充电专属内容，需要为 UP 主充电后才能观看。")
    }

    private func showAlert(title: String, message: String, dismissesPlayer: Bool = true) {
        // The player may already be dismissed (Menu pressed while loading).
        guard presentingViewController != nil, !isBeingDismissed, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in
            if dismissesPlayer { self?.dismiss(animated: true) }
        })
        present(alert, animated: true)
    }
}

/// The account's cloud danmaku block list, fetched at most every 10 minutes.
@MainActor
enum AccountDanmakuRules {
    private(set) static var cached: [JSON] = []
    private static var fetchedAt: Date?
    private static var fetchedFor: Int?

    static func refreshIfNeeded() async {
        let mid = BiliClient.shared.currentAccount?.mid
        guard AppSettings.shared.danmakuSyncAccountFilter, let mid else {
            cached = []
            return
        }
        if fetchedFor == mid, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 600 { return }
        guard let rules = try? await API.danmakuFilterRules() else { return }
        cached = rules
        fetchedAt = Date()
        fetchedFor = mid
    }
}

// MARK: 投屏

extension PlayerViewController: CastControllable {
    func castIsPlaying(_ content: CastRequest.Content) -> Bool {
        guard !isSwitchingPage, !tornDown else { return false }
        switch content {
        case let .video(aid, cid): return !request.isPGC && request.aid == aid && (cid == 0 || request.cid == cid)
        case let .episode(epID, _): return request.isPGC && request.epID == epID
        case .live: return false
        }
    }

    func castPause() {
        player?.pause()
    }

    func castResume() {
        player?.play()
    }

    func castSeek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, seconds < 1e9 else { return }
        guard let player, player.currentItem != nil, !isSwitchingPage else {
            // Still loading: start there instead (read when the item attaches).
            request.startAt = seconds
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            #if DEBUG
            Task { @MainActor in self?.updateTestMarker() }
            #endif
        }
    }

    func castSetSpeed(_ rate: Double) {
        guard let speed = speeds.first(where: { abs(Double($0.rate) - rate) < 0.01 }) else { return }
        selectSpeed(speed)
    }

    func castStatus() -> CastStatus {
        guard let player, let item = player.currentItem else {
            return CastStatus(state: .loading, aid: request.aid, cid: request.cid, epID: request.epID, seasonID: request.seasonID, title: request.displayTitle)
        }
        let state: NVA.PlayState
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .loading
        default: state = isSwitchingPage ? .loading : .paused
        }
        let duration = item.duration.seconds
        return CastStatus(state: state, position: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
                          duration: duration.isFinite ? duration : 0, speed: Double(player.defaultRate),
                          danmaku: overlay.danmakuEnabled, aid: request.aid, cid: request.cid, epID: request.epID,
                          seasonID: request.seasonID, title: request.displayTitle)
    }

    func castSetDanmaku(_ on: Bool) {
        overlay.danmakuEnabled = on
        AppSettings.shared.danmakuEnabled = on
        updateMenus()
    }
}

extension PlayerViewController: AVPlayerViewControllerDelegate {
    /// The heat curve comes and goes with the transport bar.
    func playerViewController(_: AVPlayerViewController, willTransitionToVisibilityOfTransportBar visible: Bool,
                              with coordinator: AVPlayerViewControllerAnimationCoordinator)
    {
        coordinator.addCoordinatedAnimations({ [heatBar] in heatBar.alpha = visible ? 1 : 0 }, completion: nil)
    }

    func playerViewControllerWillStartPictureInPicture(_: AVPlayerViewController) {
        PictureInPicture.willStart(self)
        heatBar.alpha = 0
    }

    func playerViewControllerDidStopPictureInPicture(_: AVPlayerViewController) {
        PictureInPicture.didStop(self)
    }

    func playerViewController(_: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        Log.player.error("picture in picture failed: \(error.localizedDescription, privacy: .public)")
        PictureInPicture.didStop(self)
    }

    func playerViewController(_: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void)
    {
        PictureInPicture.restore(self, completion: completionHandler)
    }
}
