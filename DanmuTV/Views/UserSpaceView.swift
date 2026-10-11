import BiliKit
import SwiftUI

/// UP 主主页: profile header with follow, then uploads sortable by date / views.
struct UserSpaceView: View {
    let route: UserRoute

    @State private var user: UserItem?
    @State private var order: API.UserVideoOrder = .latest
    /// Read by the grid's fetcher, so the order changes without rebuilding the grid (and losing focus).
    @State private var orderBox = OrderBox()
    @State private var following = false
    @State private var message: String?

    var body: some View {
        let mid = route.mid, box = orderBox
        // The header scrolls away with the grid; cards don't repeat the UP's own name.
        PagedGrid(emptyMessage: "还没有投稿", refreshKey: order) { page in
            try await API.userVideos(mid: mid, order: box.order, page: page)
        } header: {
            header
        } card: {
            VideoCard(item: $0, showsOwner: false)
        }
        .onChange(of: order) { orderBox.order = order }
        .task { if user == nil { await load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .center, spacing: Theme.Spacing.l) {
                Avatar(url: user?.face ?? "", size: 180)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 3))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                VStack(alignment: .leading, spacing: 10) {
                    Text(user?.name ?? route.name).font(Theme.Font.hero).lineLimit(1)
                    if let user {
                        Text("\(BiliText.formatCount(user.fans)) 粉丝").font(Theme.Font.meta).foregroundStyle(Theme.textSecondary)
                        if !user.sign.isEmpty {
                            Text(user.sign).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                .frame(maxWidth: 900, alignment: .leading)
                        }
                    }
                    if let message { Text(message).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                }
                Spacer(minLength: Theme.Spacing.l)
                Button {
                    Task { await toggleFollow() }
                } label: {
                    Label(following ? "已关注" : "关注", systemImage: following ? "checkmark" : "plus")
                        .font(Theme.Font.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 6)
                }
                .buttonBorderShape(.capsule)
                .tint(following ? nil : Theme.accent)
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.Spacing.l)
            HStack(alignment: .center, spacing: 0) {
                Text("投稿").font(Theme.Font.section).padding(.leading, Theme.pagePadding)
                // Focus starts here: a stray Select changes the sort, never the follow state.
                ChipRow(items: API.UserVideoOrder.allCases, selection: $order, leadingInset: Theme.Spacing.l, focusesByDefault: true) { Text($0.title) }
            }
        }
        .ambient(user?.face ?? "")
        .focusSection()
    }

    private func load() async {
        if let card = try? await API.userCard(mid: route.mid) {
            user = card
            following = card.isFollowing
        }
    }

    private func toggleFollow() async {
        guard BiliClient.shared.currentAccount != nil else {
            AccountStore.shared.isLoginPresented = true
            return
        }
        let target = !following
        following = target
        do {
            try await API.setFollow(mid: route.mid, following: target)
            message = nil
        } catch {
            following = !target
            message = error.localizedDescription
        }
    }
}

@MainActor
final class OrderBox {
    var order: API.UserVideoOrder = .latest
}
