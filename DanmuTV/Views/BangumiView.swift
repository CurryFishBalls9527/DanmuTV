import BiliKit
import SwiftUI

/// 番剧 / 影视: the top of the chart on the stage, then the type switcher, 我的追番, the weekly
/// schedule and the chart as posters.
struct BangumiView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var type: SeasonType = .anime
    @State private var rank: [SeasonItem] = []
    @State private var timeline: [API.TimelineDay] = []
    @State private var following: [SeasonItem] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    if rank.isEmpty, !loaded {
                        SkeletonStage()
                    } else if !rank.isEmpty {
                        Stage(entries: rank.prefix(5).enumerated().map { Self.entry($0.element, rank: $0.offset + 1) }) {
                            PlayerLauncher.playSeason(seasonID: $0.value.seasonID ?? 0)
                        }
                    }
                    // Outside the reloaded content, so switching type keeps these chips (and focus) in place.
                    ChipRow(items: SeasonType.allCases, selection: $type) { Text($0.title) }
                        .padding(.vertical, -Theme.Spacing.m)
                    if let error, rank.isEmpty {
                        ErrorRetryView(message: error) { Task { await load() } }
                    }
                    if !following.isEmpty {
                        Shelf(title: type == .anime || type == .guochuang ? "我的追番" : "我的追剧") {
                            ForEach(following) { PosterCard(item: $0).frame(width: Theme.posterCardWidth) }
                        }
                    }
                    if type.hasTimeline, !timeline.isEmpty { schedule }
                    if rank.count > 1 {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            SectionHeader(title: "\(type.title)热门榜", subtitle: "本周最多人在看")
                            FocusableGrid(items: Array(rank.enumerated()), id: \.element.id, columns: 6) {
                                PosterCard(item: $0.element, rank: $0.offset + 1)
                            }
                            .padding(.horizontal, Theme.pagePadding)
                        }
                        .focusSection()
                    } else if !loaded {
                        SkeletonGrid(columns: 6, aspect: 3 / 4).padding(.horizontal, Theme.pagePadding)
                    }
                }
                .padding(.bottom, 60)
                .id("top")
            }
            .ignoresSafeArea(edges: .top)
            .scrollClipDisabled()
            .environment(\.scrollToTop, ScrollToTopAction { withAnimation(Theme.crossfade) { proxy.scrollTo("top", anchor: .top) } })
        }
        .task(id: "\(type.rawValue)-\(accounts.currentID ?? 0)") { await load() }
        .onPlayPauseCommand { Task { await load() } }
    }

    private static func entry(_ item: SeasonItem, rank: Int) -> StageEntry<SeasonRoute> {
        let numerals = ["一", "二", "三", "四", "五"]
        return StageEntry(id: "s\(item.seasonID)", cover: item.horizontalCover.isEmpty ? item.cover : item.horizontalCover,
                          label: "热门第\(numerals.indices.contains(rank - 1) ? numerals[rank - 1] : String(rank))",
                          title: item.title, subtitle: item.subtitle, value: SeasonRoute(seasonID: item.seasonID))
    }

    /// 时间表: today first; episodes not yet out are marked with their release time.
    private var schedule: some View {
        let days = timeline.sorted { ($0.isToday ? 0 : 1, $0.date) < ($1.isToday ? 0 : 1, $1.date) }
        return Shelf(title: "时间表", subtitle: "今天更新") {
            ForEach(days.first?.items ?? [], id: \.season.id) { entry in
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    NavigationLink(value: SeasonRoute(seasonID: entry.season.seasonID)) {
                        CoverImage(url: entry.season.cover, width: 360, height: 480)
                            .overlay(alignment: .bottom) {
                                Text(entry.published ? entry.episode : "\(entry.time) 更新")
                                    .font(Theme.Font.badge)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(entry.published ? Theme.accent : Theme.scrim)
                                    .foregroundStyle(.white)
                            }
                    }
                    .buttonStyle(.card)
                    Text(entry.season.title).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary).lineLimit(1).padding(.horizontal, 6)
                }
                .frame(width: 220)
            }
        }
    }

    /// Switching type cancels the running load; a cancelled load must not touch state after the next one started.
    private func load() async {
        error = nil
        loaded = false
        do {
            async let rankTask = API.pgcRank(type)
            async let timelineTask = type.hasTimeline ? ((try? await API.timeline(type)) ?? []) : []
            let (r, t) = try await (rankTask, timelineTask)
            guard !Task.isCancelled else { return }
            rank = r
            timeline = t
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            rank = []
        }
        if let mid = accounts.current?.mid {
            let kind = type == .anime || type == .guochuang ? 1 : 2
            let f = (try? await API.followedSeasons(mid: mid, type: kind, page: 1).items) ?? []
            guard !Task.isCancelled else { return }
            following = f
        } else {
            following = []
        }
        loaded = true
    }
}
