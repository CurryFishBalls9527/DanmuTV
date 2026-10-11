import BiliKit
import SwiftUI

struct SeasonDetailView: View {
    let route: SeasonRoute

    @State private var season: Season?
    @State private var error: String?
    @State private var following = false
    @State private var showAll = false
    @State private var showShare = false
    @State private var message: String?
    /// Episode chosen in the 展开全部 sheet; played once the sheet is gone.
    @State private var pendingPlay: Int?
    /// The episode this page was opened for (from 热门 / a folder), used until the first play.
    @State private var openedEpisode: Int?
    @FocusState private var playFocused: Bool

    /// Long series get compact numbered tiles instead of identical cover cards.
    private static let compactThreshold = 30

    var body: some View {
        ScrollView {
            if let season {
                ZStack(alignment: .topLeading) {
                    StageArtwork(url: artwork(season))
                    VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                        hero(season)
                        if season.episodes.isEmpty {
                            notYetAired(season)
                        } else {
                            episodesShelf(season)
                        }
                        if season.episodes.indices.contains(targetIndex(season)) {
                            let episode = season.episodes[targetIndex(season)]
                            CommentsShelf(aid: episode.aid, title: "\(season.title) \(episode.displayTitle)", context: episode.displayTitle)
                        }
                        ForEach(Array(season.extras.enumerated()), id: \.offset) { _, extra in
                            Shelf(title: extra.title) {
                                ForEach(Array(extra.episodes.enumerated()), id: \.element.id) { i, ep in
                                    EpisodeCard(episode: ep, isCurrent: false, showsBadge: true) { play(season, episodes: extra.episodes, index: i) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, Theme.Spacing.xl)
                }
            } else if let error {
                ErrorRetryView(message: error) { Task { await load() } }.padding(.top, 200)
            } else {
                SkeletonHero(posterAspect: 3 / 4, posterWidth: 300).padding(.top, 200)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollClipDisabled()
        .ambient(season.map(artwork) ?? "")
        .defaultFocus($playFocused, true)
        .task { if season == nil { openedEpisode = route.epID; await load() } }
        // 继续播放 reflects what was just watched.
        .onReceive(NotificationCenter.default.publisher(for: .playerDismissed)) { _ in Task { await load() } }
        .sheet(isPresented: $showAll, onDismiss: {
            if let index = pendingPlay, let season { play(season, episodes: season.episodes, index: index) }
            pendingPlay = nil
        }) {
            if let season {
                AllEpisodesView(season: season, current: targetIndex(season)) { pendingPlay = $0 }
            }
        }
        .sheet(isPresented: $showShare) {
            if let season {
                ShareQRView(url: API.shareURL(epID: season.episodes.indices.contains(targetIndex(season)) ? season.episodes[targetIndex(season)].epID : nil))
            }
        }
    }

    // MARK: Hero

    /// Wide art for the stage: the episode the page is about (posters are 3:4, so they stay in the column).
    private func artwork(_ s: Season) -> String {
        let i = targetIndex(s)
        return s.episodes.indices.contains(i) ? s.episodes[i].cover : s.cover
    }

    private func hero(_ s: Season) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
            CoverImage(url: s.cover, width: 360, height: 480)
                .frame(width: 300)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 40, y: 24)

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(s.title).font(Theme.Font.hero).lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                    if s.isOversea { Badge(text: "港澳台", color: .blue) }
                    if let shared = sharedBadge(s) { Badge(text: shared, color: .gray) }
                }
                HStack(spacing: Theme.Spacing.m) {
                    if s.rating > 0 {
                        Label(String(format: "%.1f", s.rating), systemImage: "star.fill")
                            .font(Theme.Font.meta.weight(.semibold)).foregroundStyle(Theme.vipGold)
                    }
                    if !s.areas.isEmpty { Text(s.areas.joined(separator: " / ")) }
                    if !s.subtitle.isEmpty { Text(verbatim: s.subtitle) }
                }
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textSecondary)
                if !s.evaluate.isEmpty {
                    Text(s.evaluate).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
                if s.isOversea {
                    Label("该剧集仅限港澳台地区播放，需要相应网络环境", systemImage: "globe.asia.australia")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }

                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    PrimaryButton(title: playTitle(s), systemImage: "play.fill") { play(s, episodes: s.episodes, index: targetIndex(s)) }
                        .focused($playFocused)
                        .disabled(s.episodes.isEmpty)

                    ActionButton(title: following ? "已追番" : "追番", systemImage: following ? "heart.fill" : "heart", isOn: following) {
                        Task { await toggleFollow(s) }
                    }
                    ActionButton(title: "分享", systemImage: "qrcode") { showShare = true }
                }
                .padding(.top, Theme.Spacing.s)
                if let message {
                    Text(message).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .frame(minHeight: Theme.stageHeight - 60, alignment: .bottomLeading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 140)
        .focusSection()
    }

    private func notYetAired(_ s: Season) -> some View {
        StatePlaceholder(systemImage: "calendar.badge.clock", title: "即将开播",
                         message: [s.publishText, "追番后，开播时会出现在「我的追番」里"].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    // MARK: Episodes

    private func episodesShelf(_ s: Season) -> some View {
        let current = targetIndex(s)
        let compact = s.episodes.count > Self.compactThreshold
        let showsBadges = sharedBadge(s) == nil
        let lastWatched = s.episodes.firstIndex { $0.epID == s.lastEpisodeID }
        // Opens at the current episode.
        return Shelf(title: "选集", subtitle: "共 \(s.episodes.count) 集",
                     initialItem: s.episodes.indices.contains(current) ? AnyHashable(s.episodes[current].id) : nil)
        {
            ForEach(Array(s.episodes.enumerated()), id: \.element.id) { i, ep in
                Group {
                    if compact {
                        EpisodeTile(episode: ep, isCurrent: i == lastWatched) { play(s, episodes: s.episodes, index: i) }
                    } else {
                        EpisodeCard(episode: ep, isCurrent: i == lastWatched, showsBadge: showsBadges) { play(s, episodes: s.episodes, index: i) }
                    }
                }
                .id(ep.id)
            }
            if compact {
                Button {
                    showAll = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3").font(.system(size: 30))
                        Text("全部 \(s.episodes.count) 集").font(Theme.Font.caption)
                    }
                    .frame(width: 150, height: 110)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.card))
            }
        }
    }

    /// A badge every episode shares (e.g. 受限) is shown once on the season instead of on each card.
    private func sharedBadge(_ s: Season) -> String? {
        guard let first = s.episodes.first?.badge, !first.isEmpty, s.episodes.count > 1,
              s.episodes.allSatisfy({ $0.badge == first && !$0.isVIP })
        else { return nil }
        return first
    }

    private func targetIndex(_ s: Season) -> Int { s.targetIndex(opened: openedEpisode) }

    private func playTitle(_ s: Season) -> String {
        let i = targetIndex(s)
        guard s.episodes.indices.contains(i) else { return "播放" }
        let ep = s.episodes[i]
        let head = Int(ep.index) != nil ? "第\(ep.index)话" : ep.index
        if ep.epID == s.lastEpisodeID, s.lastTime > 5 { return "继续播放 \(head)" }
        return i == 0 && openedEpisode == nil ? "播放" : "播放 \(head)"
    }

    private func play(_ s: Season, episodes: [Episode], index: Int) {
        openedEpisode = nil
        PlayerLauncher.play(PlayRequest(season: s, episodes: episodes, index: index))
    }

    private func toggleFollow(_ s: Season) async {
        guard BiliClient.shared.currentAccount != nil else {
            AccountStore.shared.isLoginPresented = true
            return
        }
        let target = !following
        following = target
        do {
            try await API.setSeasonFollow(s.seasonID, following: target)
            message = target ? "已追番" : "已取消追番"
        } catch {
            following = !target
            message = error.localizedDescription
        }
    }

    private func load() async {
        error = nil
        do {
            let s = try await API.season(seasonID: route.seasonID ?? season?.seasonID, epID: route.seasonID == nil && season == nil ? route.epID : nil)
            let first = season == nil
            Log.player.info("season \(s.seasonID): last ep \(s.lastEpisodeID) at \(s.lastTime)s")
            season = s
            following = s.isFollowing
            if first { playFocused = true }
        } catch {
            if season == nil { self.error = error.localizedDescription }
        }
    }
}

struct EpisodeCard: View {
    let episode: Episode
    var isCurrent: Bool
    var showsBadge = true
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button(action: action) {
                CoverImage(url: episode.cover, width: 480, height: 270)
                    .overlay(alignment: .topTrailing) {
                        if episode.isVIP { Badge(text: "会员", color: Theme.vipGold).padding(10) }
                        else if showsBadge, !episode.badge.isEmpty { Badge(text: episode.badge, color: .gray).padding(10) }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if isCurrent { CurrentMarker().padding(10) }
                    }
            }
            .buttonStyle(.card)
            VStack(alignment: .leading, spacing: 4) {
                Text(Int(episode.index) != nil ? "第\(episode.index)话" : episode.index)
                    .font(Theme.Font.caption.weight(.semibold)).foregroundStyle(isCurrent ? Theme.accent : .secondary)
                Text(episode.longTitle.isEmpty ? " " : episode.longTitle).font(Theme.Font.card).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 360)
    }
}

/// Numbered tile for long series.
struct EpisodeTile: View {
    let episode: Episode
    var isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(Int(episode.index) != nil ? episode.index : String(episode.index.prefix(4)))
                    .font(.system(size: 36, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                Text(episode.isVIP ? "会员" : (isCurrent ? "上次看到" : episode.longTitle))
                    .font(Theme.Font.caption)
                    .foregroundStyle(episode.isVIP ? Theme.vipGold : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, height: 110)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.card))
    }
}

private struct CurrentMarker: View {
    var body: some View {
        Label("上次看到", systemImage: "clock.arrow.circlepath")
            .font(Theme.Font.badge)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(.white)
    }
}

/// 展开全部: every episode as numbered tiles, in ranges of 50, opening at the current one.
struct AllEpisodesView: View {
    let season: Season
    let current: Int
    let choose: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var range = 0
    @FocusState private var focused: Int?

    private static let rangeSize = 50

    var body: some View {
        let ranges = stride(from: 0, to: season.episodes.count, by: Self.rangeSize).map { $0 ..< min($0 + Self.rangeSize, season.episodes.count) }
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("选集").font(Theme.Font.section)
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { i, r in
                        FilterChip(isSelected: i == range) {
                            withAnimation(Theme.motion) { range = i }
                        } label: {
                            Text(verbatim: "\(r.lowerBound + 1)–\(r.upperBound)")
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.s)
            }
            .scrollClipDisabled()
            .focusSection()

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 24), count: 10), spacing: 24) {
                if ranges.indices.contains(range) {
                    ForEach(ranges[range], id: \.self) { i in
                        EpisodeTile(episode: season.episodes[i], isCurrent: i == current) {
                            choose(i)
                            dismiss()
                        }
                        .focused($focused, equals: i)
                    }
                }
            }
            .focusSection()
            Spacer()
        }
        .padding(Theme.pagePadding)
        .onAppear {
            range = current / Self.rangeSize
            focused = current
        }
    }
}
