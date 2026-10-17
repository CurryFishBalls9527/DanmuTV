import AVKit
import BiliKit
import UIKit

/// 投屏 of a plain media URL (a DLNA sender that didn't say which Bilibili video it is): just the stream, no
/// danmaku or history. The phone's play / pause / seek / stop still apply.
final class DirectCastPlayer: AVPlayerViewController, PlayerTeardown, CastControllable {
    private let url: URL
    private let castTitle: String
    private var tornDown = false

    @MainActor
    static func play(_ url: URL, title: String) {
        PlayerLauncher.present(DirectCastPlayer(url: url, title: title))
    }

    init(url: URL, title: String) {
        self.url = url
        castTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Bilibili's CDN checks the referer; other hosts get no Bilibili headers.
        let host = url.host?.lowercased() ?? ""
        let isBilibiliCDN = host.hasSuffix(".bilivideo.com") || host.hasSuffix(".bilivideo.cn") || host.hasSuffix(".akamaized.net")
        let asset = isBilibiliCDN
            ? AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": BiliClient.userAgent, "Referer": "https://www.bilibili.com"]])
            : AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        if !castTitle.isEmpty {
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = castTitle as NSString
            title.extendedLanguageTag = "und"
            item.externalMetadata = [title]
        }
        let player = AVPlayer(playerItem: item)
        #if DEBUG
        player.isMuted = UserDefaults.standard.bool(forKey: "muted")
        #endif
        self.player = player
        CastReceiver.shared.player = self
        player.play()
        Log.cast.notice("cast: playing a plain URL from \(self.url.host ?? "?", privacy: .public)")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { teardown() }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if CastReceiver.shared.player === self {
            CastReceiver.shared.playerStateChanged(PlayerLauncher.isReplacingPlayer ? .loading : .stopped)
            CastReceiver.shared.player = nil
        }
    }

    // MARK: CastControllable

    func castIsPlaying(_ content: CastRequest.Content) -> Bool { false }
    func castPause() { player?.pause() }
    func castResume() { player?.play() }

    func castSeek(to seconds: Double) {
        guard seconds.isFinite, seconds < 1e9 else { return }
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    func castSetSpeed(_ rate: Double) {
        guard rate.isFinite, (0.25 ... 4).contains(rate) else { return }
        player?.defaultRate = Float(rate)
        if player?.rate ?? 0 > 0 { player?.rate = Float(rate) }
    }

    func castSetDanmaku(_: Bool) {}

    func castStatus() -> CastStatus {
        guard let player, let item = player.currentItem else { return .stopped }
        let state: NVA.PlayState = switch player.timeControlStatus {
        case .playing: .playing
        case .waitingToPlayAtSpecifiedRate: .loading
        default: .paused
        }
        let position = player.currentTime().seconds, duration = item.duration.seconds
        return CastStatus(state: state, position: position.isFinite ? position : 0, duration: duration.isFinite ? duration : 0,
                          speed: Double(player.defaultRate), danmaku: false, title: castTitle)
    }
}
