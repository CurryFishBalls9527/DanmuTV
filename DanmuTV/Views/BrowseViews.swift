import BiliKit
import SwiftUI

/// 推荐: the lead recommendations on the stage, 继续观看 and 热门 shelves, then the feed.
struct RecommendView: View {
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        let loggedIn = accounts.isLoggedIn && !accounts.currentNeedsReLogin
        VideoGrid(stage: ("为你推荐", "更多推荐"), shelves: { AnyView(HomeShelves(showsContinueWatching: loggedIn)) }, dislikes: true) { page in
            let items = try await API.recommend(freshIndex: page)
            return (items, true)
        }
        .id(accounts.currentID)
    }
}

/// 继续观看 (unfinished history) and today's 热门, refreshed with the tab.
private struct HomeShelves: View {
    let showsContinueWatching: Bool
    @Environment(\.tabReselectCount) private var tabReselectCount
    @Environment(AppSettings.self) private var settings
    @State private var unfinished: [HistoryEntry] = []
    @State private var popular: [VideoItem] = []

    var body: some View {
        // A VStack (not a Group): modifiers on an empty Group have nothing to attach to, so its task never runs.
        VStack(alignment: .leading, spacing: 0) {
            if !unfinished.isEmpty {
                Shelf(title: "继续观看", subtitle: "接着上次看到的地方") {
                    ForEach(unfinished.prefix(12)) { HistoryCard(entry: $0).frame(width: Theme.videoCardWidth) }
                    SeeAllCard(value: LibraryRoute.history, title: "全部历史")
                }
                .padding(.top, Theme.Spacing.section)
            }
            if !popular.isEmpty {
                Shelf(title: "热门", subtitle: "大家都在看") {
                    ForEach(popular.prefix(12)) { VideoCard(item: $0).frame(width: Theme.videoCardWidth) }
                    SeeAllCard(value: FeedRoute.popular)
                }
                .padding(.top, Theme.Spacing.section)
            }
        }
        .task(id: "\(showsContinueWatching)-\(settings.popularAnonymous)") { await load() }
        .onChange(of: tabReselectCount) { Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .autoRefresh)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .playerDismissed)) { _ in
            if showsContinueWatching { Task { await loadHistory() } }
        }
        // Profile switch: logged in before and after, so the task id above doesn't change.
        .onReceive(NotificationCenter.default.publisher(for: .accountChanged)) { _ in Task { await load() } }
    }

    private func load() async {
        async let p = try? await API.popular(page: 1, anonymous: settings.popularAnonymous).items
        if showsContinueWatching {
            await loadHistory()
        } else {
            unfinished = []
            TopShelf.update([])
        }
        popular = await p ?? []
    }

    private func loadHistory() async {
        let history = (try? await API.history(after: API.HistoryCursor()).items) ?? []
        unfinished = history.filter { $0.progress >= 0 && ($0.item.duration == 0 || $0.progress < $0.item.duration - 10) }
        TopShelf.update(ContinueWatchingShelf.entries(from: history))
    }
}

struct PopularView: View {
    @Environment(AppSettings.self) private var settings
    /// Pushed from the home shelf: no stage, a title instead.
    var asPage = false

    var body: some View {
        let anonymous = settings.popularAnonymous
        VideoGrid(autoRefresh: true, stage: asPage ? nil : ("热门", "更多热门"), fetch: { page in
            let result = try await API.popular(page: page, anonymous: anonymous)
            return (result.items, !result.noMore)
        }, header: {
            if asPage { PageTitle(title: "热门", subtitle: "综合热门，实时更新") }
        })
        .id(anonymous)
    }
}

struct RankingView: View {
    @State private var category = API.rankingCategories[0]
    /// Read by the grid's fetcher: the grid keeps its first model, so a captured value would never change.
    @State private var box = RankingBox()

    var body: some View {
        let box = box
        // Ranking is a single 100-item page: the top three on a podium, the rest numbered.
        PagedGrid(autoRefresh: true, refreshKey: category, leadCount: 3, lead: { items in
            AnyView(
                HStack(alignment: .top, spacing: Theme.gridSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        VideoCard(item: item, rank: i + 1, numeralSize: 150)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .focusSection()
            )
        }, fetch: { page in
            guard page == 1 else { return ([], false) }
            return (try await API.ranking(categoryID: box.categoryID), false)
        }, header: {
            // Kept in the header so switching category refreshes in place and these chips keep focus.
            HStack(alignment: .center, spacing: 0) {
                Text("排行榜").font(Theme.Font.page).padding(.leading, Theme.pagePadding)
                ChipRow(items: API.rankingCategories, selection: $category, leadingInset: Theme.Spacing.l) { Text($0.name) }
            }
            .padding(.top, Theme.Spacing.s)
            .focusSection()
        }, rankedCard: { item, index in
            VideoCard(item: item, rank: index + 1)
        })
        .onChange(of: category) { box.categoryID = category.id }
    }
}

@MainActor
final class RankingBox {
    var categoryID = API.rankingCategories[0].id
}

/// 动态: new videos from followed uploaders.
struct DynamicView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var cursor = OffsetCursor()

    var body: some View {
        if accounts.isLoggedIn {
            let cursor = cursor
            VideoGrid(autoRefresh: true, emptyMessage: "关注的 UP 主还没有新投稿", fetch: { page in
                let gen = cursor.begin(page: page)
                let result = try await API.dynamicVideos(offset: cursor.offset(for: page))
                cursor.commit(page: page, generation: gen, offset: result.offset)
                return (result.items, result.hasMore)
            }, header: {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(title: "动态", subtitle: "关注的 UP 主的最新投稿")
                    // 动态: followed uploaders who are live right now come first.
                    FollowingLiveShelf()
                }
            })
            .id(accounts.currentID)
        } else {
            LoginPrompt(message: "登录后查看关注的 UP 主动态")
        }
    }
}

/// Carries API cursors (feed offset / history cursor) between page requests. Each refresh starts a
/// new generation; a slow load-more from an older generation can't overwrite the new cursors.
@MainActor
final class OffsetCursor {
    private var generation = 0
    /// Cursor returned by page N, i.e. the input for page N + 1.
    private var offsets: [Int: String] = [:]
    private var histories: [Int: API.HistoryCursor] = [:]

    func begin(page: Int) -> Int {
        if page == 1 {
            generation += 1
            offsets = [:]
            histories = [:]
        }
        return generation
    }

    func offset(for page: Int) -> String { page == 1 ? "" : offsets[page - 1] ?? "" }
    func historyCursor(for page: Int) -> API.HistoryCursor { page == 1 ? API.HistoryCursor() : histories[page - 1] ?? API.HistoryCursor() }

    func commit(page: Int, generation: Int, offset: String? = nil, history: API.HistoryCursor? = nil) {
        guard generation == self.generation else { return }
        if let offset { offsets[page] = offset }
        if let history { histories[page] = history }
    }
}

/// 正在直播: followed streamers currently live.
struct FollowingLiveShelf: View {
    @State private var rooms: [LiveRoom] = []
    @Environment(\.tabReselectCount) private var tabReselectCount

    var body: some View {
        VStack(spacing: 0) {
            if !rooms.isEmpty {
                Shelf(title: "正在直播", subtitle: "\(rooms.count) 位关注的主播") {
                    ForEach(rooms) { LiveRoomCard(room: $0).frame(width: Theme.videoCardWidth) }
                }
                .padding(.bottom, Theme.Spacing.s)
            }
        }
        .task { await load() }
        .onChange(of: tabReselectCount) { Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .autoRefresh)) { _ in Task { await load() } }
    }

    private func load() async {
        // Live ones are listed first; two pages cover large follow lists.
        var live: [LiveRoom] = []
        for page in 1 ... 2 {
            guard let result = try? await API.liveFollowing(page: page) else { break }
            live += result.items.filter(\.isLive)
            if !result.hasMore || result.items.last?.isLive == false { break }
        }
        rooms = live
    }
}

/// 直播: followed streamers who are live, then recommended rooms.
struct LiveView: View {
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        PagedGrid(autoRefresh: true, emptyMessage: "暂时没有推荐的直播", fetch: { page in
            page == 1 ? (try await API.liveRecommend(), false) : ([], false)
        }, header: {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "直播", subtitle: "正在直播的主播")
                if accounts.isLoggedIn { FollowingLiveShelf().id(accounts.currentID) }
            }
        }, card: { LiveRoomCard(room: $0) })
    }
}
