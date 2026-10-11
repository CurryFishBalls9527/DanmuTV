import BiliKit
import SwiftUI

@main
struct DanmuTVApp: App {
    @State private var settings = AppSettings.shared
    @State private var accounts = AccountStore.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        // Another profile's 继续观看 must not stay on the Home screen; the home shelf rewrites it for the new one.
        NotificationCenter.default.addObserver(forName: .accountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TopShelf.update([]) }
        }
        BiliClient.shared.onAuthFailure = {
            Task { @MainActor in await AccountStore.shared.handleAuthFailure() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(accounts)
        }
    }
}

struct RootView: View {
    enum Tab: Hashable, CaseIterable { case recommend, popular, ranking, dynamic, live, bangumi, search, me }

    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var accounts
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .recommend
    @State private var backgroundedAt: Date?
    @State private var recommendPath = NavigationPath()
    @State private var bangumiPath = NavigationPath()
    /// Bumped when the already-selected tab is chosen again; that tab's grid refreshes.
    @State private var reselectCounts: [Tab: Int] = [:]

    var body: some View {
        @Bindable var accounts = accounts
        // One ground for every tab: ink tinted by whatever is focused. Pages draw nothing opaque over it.
        // A background (not a ZStack sibling): its image swaps must never re-lay out the tabs' scroll views.
        Group {
            TabView(selection: tabSelection) {
                BrowseStack(path: $recommendPath) { RecommendView() }
                    .environment(\.tabReselectCount, reselectCounts[.recommend, default: 0])
                    .tabItem { Text("推荐") }
                    .tag(Tab.recommend)
                BrowseStack { PopularView() }
                    .environment(\.tabReselectCount, reselectCounts[.popular, default: 0])
                    .tabItem { Text("热门") }
                    .tag(Tab.popular)
                BrowseStack { RankingView() }
                    .environment(\.tabReselectCount, reselectCounts[.ranking, default: 0])
                    .tabItem { Text("排行榜") }
                    .tag(Tab.ranking)
                if !settings.hideDynamicTab {
                    BrowseStack { DynamicView() }
                        .environment(\.tabReselectCount, reselectCounts[.dynamic, default: 0])
                        .tabItem { Text("动态") }
                        .tag(Tab.dynamic)
                }
                BrowseStack { LiveView() }
                    .environment(\.tabReselectCount, reselectCounts[.live, default: 0])
                    .tabItem { Text("直播") }
                    .tag(Tab.live)
                BrowseStack(path: $bangumiPath) { BangumiView() }
                    .tabItem { Text("番剧") }
                    .tag(Tab.bangumi)
                BrowseStack { SearchView() }
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(Tab.search)
                BrowseStack { MeView() }
                    .tabItem { Text("我的") }
                    .tag(Tab.me)
            }
        }
        .background { AmbientBackdrop() }
        .overlay(alignment: .bottom) {
            if let text = AppNotice.shared.text {
                NoticePill(text: text).padding(.bottom, 70)
            }
        }
        .task {
            // Outside mainland China, Akamai mirrors are usually faster (CDN 策略「海外优先 Akamai」).
            if let overseas = try? await API.isOverseas() { AppSettings.isOverseas = overseas }
        }
        .task {
            #if DEBUG
            // Lets `simctl launch … -deeplink danmutv://…` drive the UI without the "Open in" prompt.
            if let link = UserDefaults.standard.string(forKey: "deeplink"), let url = URL(string: link) {
                handleDeepLink(url)
            }
            #endif
            CastReceiver.shared.start()
            await accounts.refreshTokenIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
                CastReceiver.shared.stop()
            case .active:
                CastReceiver.shared.start()
                // Pick up profiles / rotated tokens synced from other Apple TVs.
                accounts.reload()
                Task { await accounts.refreshTokenIfNeeded() }
                if let since = backgroundedAt,
                   Date().timeIntervalSince(since) > Double(settings.autoRefreshMinutes) * 60
                {
                    NotificationCenter.default.post(name: .autoRefresh, object: nil)
                }
                backgroundedAt = nil
            default:
                break
            }
        }
        // The app's only login sheet; every entry point sets `accounts.isLoginPresented`.
        .sheet(isPresented: $accounts.isLoginPresented) { LoginView() }
        .onOpenURL(perform: handleDeepLink)
    }

    private var tabSelection: Binding<Tab> {
        Binding(
            get: { tab },
            set: { newTab in
                if newTab == tab { reselectCounts[newTab, default: 0] += 1 }
                tab = newTab
            }
        )
    }

    /// `danmutv://video/<bvid>` opens the detail page; `danmutv://play/<bvid>[?p=<page>]` starts playback;
    /// `danmutv://login`, `danmutv://tab/<name>`, `danmutv://season/<id>`, `danmutv://ep/<id>`, `danmutv://user/<mid>`.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "danmutv" else { return }
        let arg = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "login":
            tab = .me
            accounts.isLoginPresented = true
            return
        case "tab":
            let tabs: [String: Tab] = ["recommend": .recommend, "popular": .popular, "ranking": .ranking, "dynamic": .dynamic, "live": .live,
                                       "bangumi": .bangumi, "search": .search, "me": .me]
            if let t = tabs[arg] { tab = t }
            return
        case "season":
            tab = .bangumi
            guard let id = Int(arg) else { return }
            bangumiPath.append(SeasonRoute(seasonID: id))
            // `?play=N` also starts episode N (1-based).
            if let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "play" })?.value.flatMap(Int.init) {
                Task {
                    guard let season = try? await API.season(seasonID: id), season.episodes.indices.contains(n - 1) else { return }
                    PlayerLauncher.play(PlayRequest(season: season, episodes: season.episodes, index: n - 1))
                }
            }
            return
        case "ep":
            // danmutv://ep/<epID>: plays a 番剧 episode, resuming (Top Shelf 继续观看).
            if let id = Int(arg) { PlayerLauncher.dismissPlayers { PlayerLauncher.playSeason(epID: id) } }
            return
        case "live":
            // danmutv://live/<roomid>
            if let id = Int(arg) {
                LiveLauncher.open(LiveRoom(roomID: id, title: "", cover: "", uname: "", face: ""))
            }
            return
        case "user":
            tab = .recommend
            if let mid = Int(arg) { recommendPath.append(UserRoute(mid: mid, name: "")) }
            return
        #if DEBUG
        case "comments":
            // danmutv://comments/<aid>: the full comment list (device checks without a remote).
            tab = .recommend
            if let aid = Int(arg) { recommendPath.append(CommentsRoute(aid: aid, title: "")) }
            return
        #endif
        default:
            break
        }
        guard let bvid = url.pathComponents.dropFirst().first, bvid.hasPrefix("BV") else { return }
        switch url.host {
        case "video":
            // e.g. Top Shelf while a player is open: close it first so the page isn't hidden behind it.
            PlayerLauncher.dismissPlayers {
                tab = .recommend
                recommendPath.append(VideoItem(bvid: bvid))
            }
        case "play":
            let explicitPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value.flatMap(Int.init)
            let page = explicitPage ?? 1
            Task {
                do {
                    let detail = try await API.videoDetail(bvid: bvid)
                    PlayerLauncher.play(PlayRequest(detail: detail, pageIndex: min(max(0, page - 1), max(0, detail.pages.count - 1)),
                                                    resumeLastPage: explicitPage == nil))
                } catch {
                    PlayerLauncher.showError(error.localizedDescription)
                }
            }
        default:
            break
        }
    }
}

/// Per-tab navigation stack with the shared destinations.
struct BrowseStack<Content: View>: View {
    var path: Binding<NavigationPath>?
    @ViewBuilder let content: () -> Content
    @State private var localPath = NavigationPath()

    var body: some View {
        let path = path ?? $localPath
        NavigationStack(path: path) {
            content()
                .navigationDestination(for: VideoItem.self) { VideoDetailView(item: $0) }
                .navigationDestination(for: SeasonRoute.self) { SeasonDetailView(route: $0) }
                .navigationDestination(for: UserRoute.self) { UserSpaceView(route: $0) }
                .navigationDestination(for: FavFolder.self) { FolderPage(folder: $0) }
                .navigationDestination(for: LibraryRoute.self) { LibraryPage(route: $0) }
                .navigationDestination(for: FeedRoute.self) { route in
                    switch route {
                    case .popular: PopularView(asPage: true)
                    }
                }
                .navigationDestination(for: SMBLocation.self) { SMBFolderView(location: $0) }
                .navigationDestination(for: CommentsRoute.self) { CommentsPage(route: $0) }
                .navigationDestination(for: CommentThreadRoute.self) { CommentThreadPage(route: $0) }
        }
        // On the stack, so pushed pages (detail, UP 主…) can push too.
        .environment(\.pushRoute, PushRouteAction { route in path.wrappedValue.append(route) })
    }
}

private struct TabReselectCountKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Increments when the user re-selects the current tab in the tab bar.
    var tabReselectCount: Int {
        get { self[TabReselectCountKey.self] }
        set { self[TabReselectCountKey.self] = newValue }
    }
}
