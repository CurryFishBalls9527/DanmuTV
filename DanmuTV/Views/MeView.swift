import BiliKit
import SwiftUI

/// Full-page lists reachable from 我的.
enum LibraryRoute: Hashable {
    case history, watchLater, favorites, followedSeasons(type: Int), followings
}

struct MeView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var pendingRemoval: Account?
    private enum HeaderFocus: Hashable { case login, local, settings }
    @FocusState private var headerFocus: HeaderFocus?
    /// Set while 本地播放 / 设置 is pushed, so returning keeps focus where it was.
    @State private var openedPage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                profileHeader
                if let account = accounts.current, !accounts.currentNeedsReLogin {
                    LibraryShelves(mid: account.mid).id(account.mid)
                } else if accounts.isLoggedIn {
                    LoginPrompt(message: "登录已失效，请重新扫码")
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .confirmationDialog("移除账户", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval)
        { account in
            Button("移除 \(account.name)", role: .destructive) { accounts.remove(account.mid) }
        }
        .defaultFocus($headerFocus, .login)
        .onChange(of: headerFocus) { before, now in
            // Coming down from the tab bar lands on whatever is below 我的 (本地播放); logged out, start on 扫码登录.
            guard before == nil, now != nil else { return }
            if !openedPage, now != .login, accounts.current == nil { headerFocus = .login }
            openedPage = false
        }
        .task { await accounts.refreshProfile() }
    }

    private var profileHeader: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            if let current = accounts.current {
                Avatar(url: current.face, size: 180)
                    .overlay(Circle().stroke(LinearGradient(colors: [Theme.accent, Theme.accentDeep.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                VStack(alignment: .leading, spacing: 10) {
                    Text(current.name.isEmpty ? "UID \(String(current.mid))" : current.name).font(Theme.Font.hero).lineLimit(1)
                    Text("UID \(String(current.mid))").font(Theme.Font.meta).foregroundStyle(Theme.textSecondary)
                }
            } else {
                // Logged out: the login button is the first thing focus lands on.
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 180))
                    .foregroundStyle(Theme.surfaceRaised)
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("欢迎使用 Danmu TV").font(Theme.Font.hero)
                    Text("登录后可以查看历史记录、稍后再看、收藏夹和追番，并使用点赞、投币等功能。")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: 820, alignment: .leading)
                    PrimaryButton(title: "扫码登录", systemImage: "qrcode") { accounts.isLoginPresented = true }
                        .focused($headerFocus, equals: .login)
                        .padding(.top, Theme.Spacing.s)
                }
            }
            Spacer(minLength: Theme.Spacing.l)
            VStack(alignment: .trailing, spacing: Theme.Spacing.s) {
                // Profiles (多账户): select to switch, long-press to remove (also possible in 设置 › 账户).
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    ForEach(accounts.accounts) { account in
                        Button {
                            accounts.switchTo(account.mid)
                        } label: {
                            VStack(spacing: 10) {
                                Avatar(url: account.face, size: 92)
                                    .overlay(Circle().stroke(account.mid == accounts.currentID ? Theme.accent : Theme.hairline, lineWidth: 4))
                                Text(account.name.isEmpty ? "UID \(String(account.mid))" : account.name)
                                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                if accounts.expiredIDs.contains(account.mid) {
                                    Text("需重新登录").font(Theme.Font.caption).foregroundStyle(.orange)
                                }
                            }
                            .frame(width: 170)
                        }
                        .buttonStyle(.borderless)
                        .contextMenu {
                            Button("移除账户", role: .destructive) { pendingRemoval = account }
                        }
                    }
                    if accounts.canAddProfile, accounts.isLoggedIn {
                        Button {
                            accounts.isLoginPresented = true
                        } label: {
                            IconTile(title: "添加账户", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    NavigationLink {
                        LocalSourcesView().onAppear { openedPage = true }
                    } label: {
                        IconTile(title: "本地播放", systemImage: "externaldrive.connected.to.line.below")
                    }
                    .buttonStyle(.borderless)
                    .focused($headerFocus, equals: .local)
                    NavigationLink {
                        SettingsView().onAppear { openedPage = true }
                    } label: {
                        IconTile(title: "设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .focused($headerFocus, equals: .settings)
                }
                if accounts.accounts.count > 1 {
                    Text("长按头像可移除账户").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.m)
        .ambient(accounts.current?.face ?? "")
        .focusSection()
    }
}

/// The account's library as shelves, each with a 全部 link to the full list.
private struct LibraryShelves: View {
    let mid: Int

    @State private var history: [HistoryEntry] = []
    @State private var watchLater: [VideoItem] = []
    @State private var folders: [FavFolder] = []
    @State private var anime: [SeasonItem] = []
    @State private var dramas: [SeasonItem] = []
    @State private var followings: [UserItem] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            if !loaded {
                SkeletonGrid().padding(.horizontal, Theme.pagePadding)
            } else if failed {
                ErrorRetryView(message: "暂时无法加载你的内容，可能被 B 站风控限制") { Task { await load() } }
            } else if history.isEmpty, watchLater.isEmpty, folders.isEmpty, anime.isEmpty, dramas.isEmpty, followings.isEmpty {
                StatePlaceholder(systemImage: "sparkles", title: "这里会放你的内容", message: "看过的、收藏的、追的番和关注的 UP 主都会出现在这里")
            }
            // Continue watching = unfinished items only; the full history is one press away.
            let unfinished = history.filter { $0.progress >= 0 && ($0.item.duration == 0 || $0.progress < $0.item.duration - 10) }
            if !unfinished.isEmpty {
                Shelf(title: "继续观看") {
                    ForEach(unfinished.prefix(15)) { HistoryCard(entry: $0).frame(width: Theme.videoCardWidth) }
                    SeeAllCard(value: LibraryRoute.history, title: "全部历史")
                }
            }
            if !watchLater.isEmpty {
                Shelf(title: "稍后再看") {
                    ForEach(watchLater.prefix(15)) { VideoCard(item: $0).frame(width: Theme.videoCardWidth) }
                    SeeAllCard(value: LibraryRoute.watchLater)
                }
            }
            if !folders.isEmpty {
                Shelf(title: "收藏夹") {
                    ForEach(folders) { FolderCard(folder: $0).frame(width: Theme.videoCardWidth) }
                    SeeAllCard(value: LibraryRoute.favorites)
                }
            }
            if !anime.isEmpty {
                Shelf(title: "我的追番") {
                    ForEach(anime) { PosterCard(item: $0).frame(width: Theme.posterCardWidth) }
                    SeeAllCard(value: LibraryRoute.followedSeasons(type: 1), width: Theme.posterCardWidth, aspect: 3 / 4)
                }
            }
            if !dramas.isEmpty {
                Shelf(title: "我的追剧") {
                    ForEach(dramas) { PosterCard(item: $0).frame(width: Theme.posterCardWidth) }
                    SeeAllCard(value: LibraryRoute.followedSeasons(type: 2), width: Theme.posterCardWidth, aspect: 3 / 4)
                }
            }
            if !followings.isEmpty {
                Shelf(title: "关注") {
                    ForEach(followings.prefix(20)) { UserCard(user: $0).frame(width: Theme.personCardWidth) }
                    SeeAllCard(value: LibraryRoute.followings, width: Theme.personCardWidth, aspect: 0.9)
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .autoRefresh)) { _ in Task { await load() } }
    }

    private func load() async {
        async let h = try? await API.history(after: API.HistoryCursor()).items
        async let w = try? await API.watchLater()
        async let f = try? await API.favFolders(mid: mid)
        async let c = try? await API.collectedFolders(mid: mid, page: 1).items
        async let a = try? await API.followedSeasons(mid: mid, type: 1, page: 1).items
        async let d = try? await API.followedSeasons(mid: mid, type: 2, page: 1).items
        async let u = try? await API.followings(mid: mid, page: 1).items
        let results = await (h, w, f, c, a, d, u)
        history = results.0 ?? []
        watchLater = results.1 ?? []
        folders = (results.2 ?? []) + (results.3 ?? [])
        anime = results.4 ?? []
        dramas = results.5 ?? []
        followings = results.6 ?? []
        failed = results.0 == nil && results.2 == nil && results.6 == nil
        loaded = true
    }
}

struct HistoryCard: View {
    let entry: HistoryEntry

    var body: some View {
        let duration = Double(max(entry.item.duration, 1))
        VideoCard(item: entry.item, progress: entry.progress < 0 ? 1 : Double(entry.progress) / duration)
    }
}

struct FolderCard: View {
    let folder: FavFolder

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            NavigationLink(value: folder) {
                CoverImage(url: folder.cover)
                    .overlay(alignment: .bottomTrailing) {
                        OverlayTag(text: "\(folder.count)", systemImage: "rectangle.stack").padding(12)
                    }
            }
            .buttonStyle(.card)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.title).font(Theme.Font.card).lineLimit(1)
                Text(folder.kind == .created ? "我的收藏夹" : folder.kind == .season ? "订阅的合集" : "订阅的收藏夹")
                    .font(Theme.Font.meta).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 6)
        }
    }
}

/// Full-page library lists.
struct LibraryPage: View {
    let route: LibraryRoute
    @Environment(AccountStore.self) private var accounts
    @State private var cursor = OffsetCursor()

    var body: some View {
        let mid = accounts.current?.mid ?? 0
        // tvOS draws no navigation-bar title, so each list leads with its own.
        switch route {
        case .history:
            let cursor = cursor
            PagedGrid(emptyMessage: "还没有观看记录", fetch: { page in
                let gen = cursor.begin(page: page)
                let r = try await API.history(after: cursor.historyCursor(for: page))
                cursor.commit(page: page, generation: gen, history: r.next)
                return (r.items, r.hasMore)
            }, header: { PageTitle(title: "历史记录") }, card: { HistoryCard(entry: $0) })
        case .watchLater:
            VideoGrid(emptyMessage: "稍后再看列表是空的", fetch: { page in
                page == 1 ? (try await API.watchLater(), false) : ([], false)
            }, header: { PageTitle(title: "稍后再看") })
        case .favorites:
            PagedGrid(emptyMessage: "还没有收藏夹", fetch: { page in
                // Own folders and the first page of subscribed folders/collections, then more subscribed ones.
                if page == 1 {
                    async let own = API.favFolders(mid: mid)
                    async let collected = API.collectedFolders(mid: mid, page: 1)
                    let c = try await collected
                    return (try await own + c.items, c.hasMore)
                }
                return try await API.collectedFolders(mid: mid, page: page)
            }, header: { PageTitle(title: "收藏夹") }, card: { FolderCard(folder: $0) })
        case let .followedSeasons(type):
            PagedGrid(columns: 6, aspect: 3 / 4, emptyMessage: type == 1 ? "还没有追番" : "还没有追剧", fetch: { page in
                try await API.followedSeasons(mid: mid, type: type, page: page)
            }, header: { PageTitle(title: type == 1 ? "我的追番" : "我的追剧") }, card: { PosterCard(item: $0) })
        case .followings:
            PagedGrid(columns: 5, aspect: 1, emptyMessage: "还没有关注任何人", fetch: { page in
                try await API.followings(mid: mid, page: page)
            }, header: { PageTitle(title: "关注") }, card: { UserCard(user: $0) })
        }
    }
}

struct FolderPage: View {
    let folder: FavFolder

    var body: some View {
        VideoGrid(emptyMessage: "收藏夹是空的", fetch: { page in
            try await API.folderContents(folder, page: page)
        }, header: { PageTitle(title: folder.title, subtitle: "\(folder.count) 个视频") })
    }
}
