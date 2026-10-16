import BiliKit
import SwiftUI
import UIKit

/// What to play: the parts of a UGC video, or the episodes of a season (PGC).
struct PlayRequest {
    struct Entry {
        var aid: Int
        var bvid: String
        var cid: Int
        /// PGC episode id; 0 for UGC parts.
        var epID: Int
        /// "P2 标题" / "第3话 标题".
        var title: String
        var isVIP: Bool
        var skips: [SkipRange]
    }

    var entries: [Entry]
    var pageIndex: Int
    /// Video or season title.
    var title: String
    var ownerName: String
    var ownerMid = 0
    var cover: String
    var isChargeOnly: Bool
    /// PGC season id (0 for UGC).
    var seasonID: Int
    /// PGC season type (sub_type for progress reports).
    var seasonType = 1
    /// From the main 播放 button: jump to the part the account last watched, if any (UGC).
    var resumeLastPage = false
    /// PGC history: (episode, seconds) to resume.
    var pgcResume: (epID: Int, time: Double)?
    /// 投屏: where the phone was; overrides history for the first page played.
    var startAt: Double?

    init(detail: VideoDetail, pageIndex: Int, resumeLastPage: Bool = false) {
        // The pagelist fallback has no aid; history reporting needs it.
        let aid = detail.item.aid > 0 ? detail.item.aid : (BVID.aid(from: detail.item.bvid) ?? 0)
        let multi = detail.pages.count > 1
        entries = detail.pages.map {
            Entry(aid: aid, bvid: detail.item.bvid, cid: $0.cid, epID: 0,
                  title: multi ? "P\($0.page) \($0.part)" : detail.item.title, isVIP: false, skips: [])
        }
        self.pageIndex = pageIndex
        title = detail.item.title
        ownerName = detail.item.ownerName
        ownerMid = detail.item.ownerMid
        cover = detail.item.cover
        isChargeOnly = detail.isChargeOnly
        seasonID = 0
        self.resumeLastPage = resumeLastPage
    }

    init(season: Season, episodes: [Episode], index: Int) {
        entries = episodes.map {
            Entry(aid: $0.aid, bvid: $0.bvid, cid: $0.cid, epID: $0.epID, title: $0.displayTitle, isVIP: $0.isVIP, skips: $0.skips)
        }
        pageIndex = index
        title = season.title
        ownerName = season.title
        cover = season.cover
        isChargeOnly = false
        seasonID = season.seasonID
        seasonType = season.type
        if season.lastEpisodeID > 0 { pgcResume = (season.lastEpisodeID, season.lastTime) }
    }

    var current: Entry { entries[min(max(0, pageIndex), max(0, entries.count - 1))] }
    var isPGC: Bool { seasonID > 0 }
    var aid: Int { current.aid }
    var bvid: String { current.bvid }
    var cid: Int { entries.isEmpty ? 0 : current.cid }
    var epID: Int { current.epID }
    var hasNextPage: Bool { pageIndex + 1 < entries.count }
    var displayTitle: String { entries.count > 1 || isPGC ? current.title : title }
    /// UGC parts as VideoPage, for PlaybackPolicy.
    var pages: [VideoPage] { entries.enumerated().map { VideoPage(cid: $1.cid, page: $0 + 1, part: $1.title, duration: 0) } }
}

/// Players release audio, sockets and timers here; called on dismissal and when replaced.
@MainActor
protocol PlayerTeardown: AnyObject {
    func teardown()
}

@MainActor
enum PlayerLauncher {
    /// Presents the native player modally from UIKit so the remote's Menu button
    /// dismisses it exactly like the system TV app.
    static func play(_ request: PlayRequest) {
        present(PlayerViewController(request: request))
    }

    /// A start already in progress (detail / season fetch); a second press while it runs is ignored.
    private static var starting = false

    /// Plays a video straight from a card or the stage (resuming the last page), fetching its detail first.
    static func playVideo(bvid: String, aid: Int = 0) {
        start {
            let detail = bvid.isEmpty ? try await API.videoDetail(aid: aid) : try await API.videoDetail(bvid: bvid)
            if detail.redirectEpID > 0 {
                // A 番剧 episode posing as a video: same start, season flow (not a second guarded start).
                try await startSeason(seasonID: nil, epID: detail.redirectEpID)
            } else {
                play(PlayRequest(detail: detail, pageIndex: 0, resumeLastPage: true))
            }
        }
    }

    /// Plays a season from the stage: the episode asked for, else the last watched, else the first.
    static func playSeason(seasonID: Int? = nil, epID: Int? = nil, startAt: Double = 0) {
        start { try await startSeason(seasonID: seasonID, epID: epID, startAt: startAt) }
    }

    /// 投屏: the part (cid) the phone was on, from where it was.
    static func playCast(aid: Int, cid: Int, startAt: Double) {
        start(latestWins: true) {
            let detail = try await API.videoDetail(aid: aid)
            if detail.redirectEpID > 0 {
                try await startSeason(seasonID: nil, epID: detail.redirectEpID, startAt: startAt)
                return
            }
            let page = detail.pages.firstIndex { $0.cid == cid }
            var request = PlayRequest(detail: detail, pageIndex: page ?? 0, resumeLastPage: page == nil)
            if startAt > 0 { request.startAt = startAt }
            play(request)
        }
    }

    /// 投屏: a 番剧 episode, from where the phone was.
    static func playCast(seasonID: Int?, epID: Int, startAt: Double) {
        start(latestWins: true) { try await startSeason(seasonID: seasonID, epID: epID, startAt: startAt) }
    }

    private static func startSeason(seasonID: Int?, epID: Int?, startAt: Double = 0) async throws {
        let season = try await API.season(seasonID: seasonID, epID: epID)
        guard !season.episodes.isEmpty else { return showError("这部剧集还没有可以播放的内容") }
        var request = PlayRequest(season: season, episodes: season.episodes, index: season.targetIndex(opened: epID))
        if startAt > 0 { request.startAt = startAt }
        play(request)
    }

    /// A cast that arrived while another start was running; it runs next (only the newest is kept).
    private static var queued: (@MainActor () async throws -> Void)?

    /// Runs one start at a time; errors become an alert. A second press while one runs is ignored, but a cast
    /// (`latestWins`) is queued so the phone's latest choice still plays.
    private static func start(latestWins: Bool = false, _ work: @escaping @MainActor () async throws -> Void) {
        guard !starting else {
            if latestWins { queued = work }
            return
        }
        starting = true
        Task {
            do {
                try await work()
            } catch {
                Log.player.error("start failed: \(error.localizedDescription, privacy: .public)")
                showError(error.localizedDescription)
            }
            starting = false
            if let next = queued {
                queued = nil
                start(next)
            }
        }
    }

    /// True while `present` tears down the player it replaces (it's not the viewer closing it).
    static private(set) var isReplacingPlayer = false

    /// Presents a player (VOD or live). Any player already open is torn down first, so audio,
    /// chat sockets and progress reports never keep running underneath (players never stack).
    static func present(_ controller: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        PictureInPicture.end(except: controller)
        guard let root = rootViewController() else {
            // Cold launch from Top Shelf: the window may not exist yet.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if rootViewController() != nil { present(controller, animated: animated, completion: completion) } else { completion?() }
            }
            return
        }
        var chain: [UIViewController] = []
        var node = root.presentedViewController
        while let n = node {
            chain.append(n)
            node = n.presentedViewController
        }
        if chain.isEmpty {
            root.present(controller, animated: animated, completion: completion)
            return
        }
        isReplacingPlayer = true
        chain.compactMap { $0 as? PlayerTeardown }.forEach { $0.teardown() }
        isReplacingPlayer = false
        root.dismiss(animated: false) { root.present(controller, animated: animated, completion: completion) }
    }

    /// Whether a player (VOD or live) is on screen.
    static var isPlayerShowing: Bool {
        var node = rootViewController()?.presentedViewController
        while let n = node {
            if n is PlayerTeardown { return true }
            node = n.presentedViewController
        }
        return false
    }

    static func rootViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)?.rootViewController
    }

    /// Closes any open player (e.g. before navigating from a deep link).
    static func dismissPlayers(then action: @escaping () -> Void) {
        guard let root = rootViewController(), root.presentedViewController != nil else { return action() }
        var node = root.presentedViewController
        while let n = node {
            (n as? PlayerTeardown)?.teardown()
            node = n.presentedViewController
        }
        root.dismiss(animated: true, completion: action)
    }

    static func showError(_ message: String) {
        let alert = UIAlertController(title: "无法打开", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        topViewController()?.present(alert, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension Season {
    /// The episode a page or the stage is about: the one it was opened for, else the last watched, else the first.
    func targetIndex(opened epID: Int?) -> Int {
        epID.flatMap { id in episodes.firstIndex { $0.epID == id } }
            ?? episodes.firstIndex { $0.epID == lastEpisodeID }
            ?? 0
    }
}

/// Content of the player's swipe-down info tab.
struct PlayerInfoPanel: View {
    let title: String
    let subtitle: String
    var cover = ""
    let actions: VideoActions?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            if !cover.isEmpty {
                CoverImage(url: cover, width: 480, height: 270)
                    .frame(width: 280)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Theme.Font.headline).lineLimit(2)
                Text(subtitle).font(Theme.Font.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 700, alignment: .leading)
            Spacer()
            if let actions {
                VideoActionRow(actions: actions, compact: true)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, Theme.Spacing.m)
    }
}

extension Notification.Name {
    /// Posted when the player closes, so pages can refresh resume state.
    static let playerDismissed = Notification.Name("DanmuTV.playerDismissed")
}
