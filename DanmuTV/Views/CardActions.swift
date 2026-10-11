import BiliKit
import SwiftUI

// MARK: Environment actions

/// Pushes a route onto the enclosing tab's navigation stack (set by `BrowseStack`).
/// Always equal, so setting it never invalidates the views that read it — which means readers keep the first
/// closure they saw: it must only capture things that never change for that view (the stack's path binding).
struct PushRouteAction: Equatable {
    let push: (any Hashable) -> Void
    func callAsFunction(_ route: some Hashable) { push(route) }
    static func == (_: Self, _: Self) -> Bool { true }
}

/// 不感兴趣 on a feed card: hides it from the feed it came from (set only by the 推荐 grid). Always equal, like
/// `PushRouteAction`: it captures the grid's model, which lives as long as the grid.
struct DislikeAction: Equatable {
    let dislike: (VideoItem) -> Void
    func callAsFunction(_ item: VideoItem) { dislike(item) }
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var pushRoute: PushRouteAction?
    @Entry var dislike: DislikeAction?
}

// MARK: Card menu

/// Long-press menu of a video card: 稍后再看, 不感兴趣 (home feed), the uploader's page.
struct VideoCardMenu: ViewModifier {
    let item: VideoItem
    /// Off on the uploader's own page, where "UP 主" would push the same page again.
    var showsOwner = true
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.dislike) private var dislike

    func body(content: Content) -> some View {
        content.contextMenu {
            if aid > 0 {
                Button("稍后再看", systemImage: "clock") { addToWatchLater() }
            }
            if let dislike {
                Button("不感兴趣", systemImage: "hand.thumbsdown") { notInterested(dislike) }
            }
            if showsOwner, item.ownerMid > 0, let pushRoute {
                Button(item.ownerName.isEmpty ? "UP 主页" : "UP 主：\(item.ownerName)", systemImage: "person.crop.circle") {
                    pushRoute(UserRoute(mid: item.ownerMid, name: item.ownerName))
                }
            }
        }
    }

    private var aid: Int { item.aid > 0 ? item.aid : (BVID.aid(from: item.bvid) ?? 0) }

    private func notInterested(_ dislike: DislikeAction) {
        dislike(item)
        // Logged out there's no one to tell: the card is only hidden.
        guard BiliClient.shared.currentAccount != nil else { return AppNotice.shared.show("已隐藏") }
        AppNotice.shared.show("将减少这类推荐")
        let (aid, mid) = (item.aid, item.ownerMid)
        Task {
            do {
                try await API.dislikeRecommendation(aid: aid, ownerMid: mid)
            } catch {
                Log.network.error("dislike feedback failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func addToWatchLater() {
        guard BiliClient.shared.currentAccount != nil else {
            AppNotice.shared.show("登录后可以使用稍后再看")
            return
        }
        let aid = aid
        Task {
            do {
                try await API.setWatchLater(aid: aid, added: true)
                AppNotice.shared.show("已加入稍后再看")
            } catch {
                AppNotice.shared.show(error.localizedDescription)
            }
        }
    }
}

// MARK: Notices

/// Brief app-wide confirmation (e.g. 已加入稍后再看), drawn by `RootView`.
@MainActor
@Observable
final class AppNotice {
    static let shared = AppNotice()
    private(set) var text: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        withAnimation(Theme.motion) { self.text = text }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.motion) { self?.text = nil }
        }
    }
}

struct NoticePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.headline)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
