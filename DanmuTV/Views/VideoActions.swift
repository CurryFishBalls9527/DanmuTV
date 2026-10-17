import BiliKit
import SwiftUI

/// Like / coin / favourite / watch later / follow for one video, shared by the detail page and the
/// player's swipe-down info panel. Writes are optimistic and roll back on failure.
@MainActor
@Observable
final class VideoActions {
    let aid: Int
    let bvid: String
    let ownerMid: Int
    /// 2 coins for originals, 1 for reposts (copyright 2).
    let coinLimit: Int

    private(set) var relation: Relation?
    private(set) var inWatchLater = false
    /// Last error or confirmation, shown briefly.
    var message: String?
    var showFavoritePicker = false
    var showCoinPicker = false

    init(aid: Int, bvid: String, ownerMid: Int, copyright: Int = 1) {
        self.aid = aid > 0 ? aid : (BVID.aid(from: bvid) ?? 0)
        self.bvid = bvid
        self.ownerMid = ownerMid
        coinLimit = copyright == 2 ? 1 : 2
    }

    var coinsLeft: Int { max(0, coinLimit - (relation?.coins ?? 0)) }

    var isLoggedIn: Bool { BiliClient.shared.currentAccount != nil }

    func load() async {
        guard isLoggedIn, aid > 0 else { return }
        async let r = try? await API.relation(aid: aid, bvid: bvid)
        async let w = try? await API.isInWatchLater(aid: aid)
        relation = await r ?? Relation()
        inWatchLater = await w ?? false
    }

    func toggleLike() async {
        guard requireLogin(), var r = await currentRelation() else { return }
        r.liked.toggle()
        await perform(r, success: r.liked ? "已点赞" : "已取消点赞") { try await API.like(aid: self.aid, r.liked) }
    }

    func coin(_ count: Int, alsoLike: Bool) async {
        guard requireLogin(), var r = await currentRelation() else { return }
        guard count <= coinsLeft else {
            message = "已投满 \(coinLimit) 枚"
            return
        }
        r.coins += count
        if alsoLike { r.liked = true }
        await perform(r, success: "投币成功 ×\(count)") { try await API.coin(aid: self.aid, count: count, alsoLike: alsoLike) }
    }

    func toggleFollow() async {
        guard requireLogin(), var r = await currentRelation(), ownerMid > 0 else { return }
        r.followingOwner.toggle()
        await perform(r, success: r.followingOwner ? "已关注" : "已取消关注") { try await API.setFollow(mid: self.ownerMid, following: r.followingOwner) }
    }

    func toggleWatchLater() async {
        guard requireLogin() else { return }
        let adding = !inWatchLater
        inWatchLater = adding
        do {
            try await API.setWatchLater(aid: aid, added: adding)
            message = adding ? "已添加到稍后再看" : "已从稍后再看移除"
        } catch {
            inWatchLater = !adding
            message = error.localizedDescription
        }
    }

    /// Adds to / removes from one folder; returns whether it succeeded.
    @discardableResult
    func setFavorite(folder: Int, _ included: Bool, anyRemaining: Bool) async -> Bool {
        do {
            try await API.setFavorite(aid: aid, add: included ? [folder] : [], remove: included ? [] : [folder])
            relation?.favorited = included || anyRemaining
            message = included ? "已收藏" : "已取消收藏"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// One-press favourite for the player panel: toggles the default (first) folder.
    func quickFavorite() async {
        guard requireLogin() else { return }
        let mid = BiliClient.shared.currentAccount?.mid ?? 0
        guard let folders = try? await API.favFolders(mid: mid, aid: aid), let first = folders.first else {
            message = "无法获取收藏夹"
            return
        }
        let inFirst = first.containsVideo
        await setFavorite(folder: first.id, !inFirst, anyRemaining: folders.dropFirst().contains(where: \.containsVideo))
    }

    private func perform(_ optimistic: Relation, success: String, _ body: @escaping () async throws -> Void) async {
        let previous = relation
        relation = optimistic
        do {
            try await body()
            message = success
        } catch {
            relation = previous
            message = error.localizedDescription
        }
    }

    /// The relation, fetched now if it wasn't (logged in from this page, or the first fetch failed).
    private func currentRelation() async -> Relation? {
        if relation == nil { await load() }
        return relation
    }

    private func requireLogin() -> Bool {
        guard isLoggedIn else {
            AccountStore.shared.isLoginPresented = true
            return false
        }
        return true
    }
}

/// The row of interaction buttons.
struct VideoActionRow: View {
    @Bindable var actions: VideoActions
    var showFollow = true
    var shareURL: String?
    /// Inside the player's info panel: no dialogs/sheets (1 coin + like, default folder), inline feedback.
    var compact = false
    @State private var showShare = false

    var body: some View {
        HStack(spacing: 14) {
            let r = actions.relation
            ActionButton(title: r?.liked == true ? "已点赞" : "点赞", systemImage: r?.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup",
                         isOn: r?.liked == true) { Task { await actions.toggleLike() } }
            ActionButton(title: (r?.coins ?? 0) > 0 ? "已投 \(r!.coins)" : "投币", systemImage: "bitcoinsign.circle",
                         isOn: (r?.coins ?? 0) > 0)
            {
                if !actions.isLoggedIn { AccountStore.shared.isLoginPresented = true }
                else if actions.coinsLeft == 0 { actions.message = "已投满 \(actions.coinLimit) 枚" }
                else if compact { Task { await actions.coin(1, alsoLike: true) } }
                else { actions.showCoinPicker = true }
            }
            ActionButton(title: r?.favorited == true ? "已收藏" : "收藏", systemImage: r?.favorited == true ? "star.fill" : "star",
                         isOn: r?.favorited == true)
            {
                if !actions.isLoggedIn { AccountStore.shared.isLoginPresented = true }
                else if compact { Task { await actions.quickFavorite() } }
                else { actions.showFavoritePicker = true }
            }
            ActionButton(title: "稍后再看", systemImage: actions.inWatchLater ? "clock.fill" : "clock",
                         isOn: actions.inWatchLater) { Task { await actions.toggleWatchLater() } }
            if showFollow, actions.ownerMid > 0 {
                ActionButton(title: r?.followingOwner == true ? "已关注" : "关注",
                             systemImage: r?.followingOwner == true ? "person.fill.checkmark" : "person.badge.plus",
                             isOn: r?.followingOwner == true) { Task { await actions.toggleFollow() } }
            }
            if let shareURL {
                ActionButton(title: "分享", systemImage: "qrcode") { showShare = true }
                    .sheet(isPresented: $showShare) { ShareQRView(url: shareURL) }
            }
        }
        .task { await actions.load() }
        .confirmationDialog("投币（还可投 \(actions.coinsLeft) 枚）", isPresented: $actions.showCoinPicker) {
            Button("投 1 枚并点赞") { Task { await actions.coin(1, alsoLike: true) } }
            if actions.coinsLeft >= 2 {
                Button("投 2 枚并点赞") { Task { await actions.coin(2, alsoLike: true) } }
            }
            Button("投 1 枚") { Task { await actions.coin(1, alsoLike: false) } }
        }
        .sheet(isPresented: $actions.showFavoritePicker) {
            FavoritePicker(actions: actions)
        }
        .overlay(alignment: compact ? .topTrailing : .bottomLeading) {
            if let message = actions.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(Theme.Font.meta.weight(.medium))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: compact ? -56 : 76)
                    .transition(.opacity.combined(with: .move(edge: compact ? .top : .bottom)))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        actions.message = nil
                    }
            }
        }
        .animation(Theme.motion, value: actions.message)
    }
}

/// Choose which folders hold the video. Each toggle is applied immediately (nothing is lost on Menu).
struct FavoritePicker: View {
    let actions: VideoActions
    @State private var folders: [FavFolder] = []
    @State private var selected: Set<Int> = []
    @State private var busy: Set<Int> = []
    @State private var phase: Phase = .loading

    private enum Phase { case loading, loaded, failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()
                case let .failed(message):
                    ErrorRetryView(message: message) { Task { await load() } }
                case .loaded:
                    if folders.isEmpty {
                        EmptyStateView(message: "还没有收藏夹，请先在手机上创建", systemImage: "star")
                    } else {
                        List(folders) { folder in
                            Button {
                                Task { await toggle(folder) }
                            } label: {
                                HStack {
                                    Text(folder.title)
                                    Spacer()
                                    Text("\(folder.count)").foregroundStyle(.secondary)
                                    if busy.contains(folder.id) {
                                        ProgressView()
                                    } else {
                                        Image(systemName: selected.contains(folder.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(folder.id) ? Theme.accent : .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("收藏到")
        }
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            folders = try await API.favFolders(mid: BiliClient.shared.currentAccount?.mid ?? 0, aid: actions.aid)
            selected = Set(folders.filter(\.containsVideo).map(\.id))
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func toggle(_ folder: FavFolder) async {
        let include = !selected.contains(folder.id)
        busy.insert(folder.id)
        let remaining = !selected.subtracting([folder.id]).isEmpty
        if await actions.setFavorite(folder: folder.id, include, anyRemaining: remaining) {
            if include { selected.insert(folder.id) } else { selected.remove(folder.id) }
        }
        busy.remove(folder.id)
    }
}

/// QR code of a clean (tracking-free) link to open on the phone.
struct ShareQRView: View {
    let url: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let image = LoginView.qrCode(url) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 420, height: 420)
                    .padding(30)
                    .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
            }
            Text("用手机扫码，在哔哩哔哩 App 里打开").font(Theme.Font.headline).padding(.top, Theme.Spacing.s)
            Text(url).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .padding(60)
    }
}
