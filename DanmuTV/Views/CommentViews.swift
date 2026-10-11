import BiliKit
import SwiftUI

/// All 热门评论 of a video / episode.
struct CommentsRoute: Hashable {
    var aid: Int
    var title: String
}

/// One comment with its replies.
struct CommentThreadRoute: Hashable {
    var aid: Int
    var comment: Comment
}

/// Likes given in this session, so every card showing a comment agrees with its thread page (and a second
/// 点赞 isn't sent for one already liked). Cleared when the account changes.
@MainActor
@Observable
final class CommentLikes {
    static let shared = CommentLikes()

    private var overrides: [Int: (liked: Bool, likes: Int)] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .accountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CommentLikes.shared.overrides = [:] }
        }
    }

    func liked(_ c: Comment) -> Bool { overrides[c.id]?.liked ?? c.liked }
    func likes(_ c: Comment) -> Int { overrides[c.id]?.likes ?? c.likes }

    func set(_ c: Comment, liked: Bool) {
        let current = likes(c)
        let delta = liked == self.liked(c) ? 0 : (liked ? 1 : -1)
        overrides[c.id] = (liked, max(0, current + delta))
    }
}

/// 热门评论 on a detail page: the top ten, then a card opening all of them. Hidden when the video
/// has none or comments are closed.
struct CommentsShelf: View {
    let aid: Int
    let title: String
    /// e.g. the episode the comments belong to.
    var context: String?
    @Environment(AccountStore.self) private var accounts
    @State private var page: CommentPage?
    /// The aid `page` belongs to: coming back from a thread keeps the shelf (and focus on its card).
    @State private var loadedAID = 0
    private static let shown = 10
    @State private var reload = 0

    var body: some View {
        // A stable container: `.task` must not hop between branches (and never runs on an empty Group).
        VStack(spacing: 0) {
            if let page, !page.comments.isEmpty {
                Shelf(title: "热门评论", subtitle: [context, "共 \(BiliText.formatCount(page.total)) 条"].compactMap { $0 }.joined(separator: " · ")) {
                    ForEach(page.comments.prefix(Self.shown)) { comment in
                        NavigationLink(value: CommentThreadRoute(aid: aid, comment: comment)) {
                            CommentCard(comment: comment, lineLimit: 4)
                                .frame(width: CommentCard.shelfWidth, height: CommentCard.shelfHeight, alignment: .topLeading)
                        }
                        .buttonStyle(.card)
                    }
                    if page.hasMore || page.comments.count > Self.shown {
                        SeeAllCard(value: CommentsRoute(aid: aid, title: title), title: "全部评论",
                                   width: 360, aspect: 360 / CommentCard.shelfHeight)
                    } else if accounts.current == nil, page.total > page.comments.count {
                        // Bilibili shows logged-out viewers only the top three.
                        LoginForMoreCard()
                    }
                }
            }
        }
        // Logging in from the shelf (or anywhere) reloads it with the full list.
        .onReceive(NotificationCenter.default.publisher(for: .accountChanged)) { _ in loadedAID = 0; reload += 1 }
        .task(id: "\(aid)-\(reload)") {
            guard aid > 0, loadedAID != aid else { return }
            do {
                page = try await API.comments(aid: aid).page
                loadedAID = aid
            } catch {
                // Comments closed (12002), 风控 or offline: the page simply has no comment shelf.
                if !BiliClient.isCancellation(error) {
                    page = nil
                    Log.network.info("comments for av\(aid) unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

/// Shelf end card for logged-out viewers: opens login.
private struct LoginForMoreCard: View {
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        Button {
            accounts.isLoginPresented = true
        } label: {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 84, height: 84)
                    .background(Theme.surfaceRaised, in: Circle())
                Text("登录后查看全部评论").font(Theme.Font.card)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 360, height: CommentCard.shelfHeight)
            .background(Theme.surface)
        }
        .buttonStyle(.card)
        .accessibilityLabel("登录后查看全部评论")
    }
}

/// A comment on a card platter: who, what, and its likes / replies. Text truncates inside the card's frame.
struct CommentCard: View {
    static let shelfWidth: CGFloat = 640
    static let shelfHeight: CGFloat = 330
    static let gridHeight: CGFloat = 380

    let comment: Comment
    var lineLimit: Int = 4
    var messageFont: Font = Theme.Font.body

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CommentAuthor(comment: comment)
            Text(comment.displayText)
                .font(messageFont)
                .lineLimit(lineLimit)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            CommentFooter(comment: comment)
        }
        .padding(Theme.Spacing.m)
        .background(Theme.surface)
        .accessibilityElement(children: .combine)
    }
}

struct CommentAuthor: View {
    let comment: Comment
    var avatarSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: comment.face, size: avatarSize)
            Text(comment.name)
                .font(Theme.Font.meta.weight(.semibold))
                .foregroundStyle(comment.isVIP ? Theme.accent : .white)
                .lineLimit(1)
            if comment.level > 0 {
                Text("LV\(comment.level)")
                    .font(Theme.Font.badge)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1.5))
            }
            if comment.isPinned { Badge(text: "置顶") }
        }
    }
}

struct CommentFooter: View {
    let comment: Comment

    var body: some View {
        let likes = CommentLikes.shared.likes(comment)
        HStack(spacing: Theme.Spacing.m) {
            Label(likes > 0 ? BiliText.formatCount(likes) : "赞",
                  systemImage: CommentLikes.shared.liked(comment) ? "hand.thumbsup.fill" : "hand.thumbsup")
            if comment.replyCount > 0 {
                Label(BiliText.formatCount(comment.replyCount), systemImage: "bubble.left")
            }
            if comment.upLiked {
                Text("UP 主觉得很赞").foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
            Text(comment.displayTime)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.textTertiary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}

/// Every comment, most liked first, two to a row.
struct CommentsPage: View {
    let route: CommentsRoute
    /// Page N's cursor comes from page N - 1.
    @State private var cursor = OffsetCursor()

    var body: some View {
        let cursor = cursor
        PagedGrid(columns: 2, aspect: 2.25, emptyMessage: "还没有评论", fetch: { page in
            let generation = cursor.begin(page: page)
            let r = try await API.comments(aid: route.aid, offset: cursor.offset(for: page))
            cursor.commit(page: page, generation: generation, offset: r.nextOffset ?? "")
            return (r.page.comments, r.page.hasMore)
        }, header: {
            PageTitle(title: "评论", subtitle: route.title)
        }, card: { comment in
            NavigationLink(value: CommentThreadRoute(aid: route.aid, comment: comment)) {
                CommentCard(comment: comment, lineLimit: 5)
                    .frame(height: CommentCard.gridHeight, alignment: .topLeading)
            }
            .buttonStyle(.card)
        })
    }
}

/// A comment in full, with 点赞 and its replies below. The like button sits above the text, so the page opens
/// at the comment's first line however long it is.
struct CommentThreadPage: View {
    let route: CommentThreadRoute

    var body: some View {
        if route.comment.replyCount > 0 {
            PagedGrid(columns: 2, aspect: 2.6, emptyMessage: "还没有回复", fetch: { page in
                let r = try await API.commentReplies(aid: route.aid, root: route.comment.id, page: page)
                return (r.comments, r.hasMore)
            }, header: {
                CommentThreadHeader(route: route)
            }, card: { reply in
                ReplyCard(comment: reply)
            })
        } else {
            ScrollView {
                CommentThreadHeader(route: route)
                Text("暂无回复").font(Theme.Font.meta).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.pagePadding)
            }
        }
    }
}

private struct CommentThreadHeader: View {
    let route: CommentThreadRoute
    @Environment(AccountStore.self) private var accounts
    @State private var busy = false

    var body: some View {
        let comment = route.comment
        let liked = CommentLikes.shared.liked(comment)
        let likes = CommentLikes.shared.likes(comment)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                CommentAuthor(comment: comment, avatarSize: 64)
                Button {
                    toggleLike()
                } label: {
                    Label(likes > 0 ? BiliText.formatCount(likes) : "点赞", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonBorderShape(.capsule)
                .accessibilityLabel(liked ? "已点赞，\(likes)" : "点赞，\(likes)")
                Group {
                    if comment.upLiked { Text("UP 主觉得很赞").foregroundStyle(Theme.accent) }
                    if !comment.location.isEmpty { Text(comment.location) }
                    Text(comment.displayTime)
                }
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            Text(comment.displayText)
                .font(Theme.Font.headline.weight(.regular))
                .lineSpacing(10)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1400, alignment: .leading)
            if comment.replyCount > 0 {
                SectionHeader(title: "回复", subtitle: "共 \(comment.replyCount) 条").padding(.horizontal, -Theme.pagePadding)
                    .padding(.top, Theme.Spacing.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.m)
        .focusSection()
    }

    private func toggleLike() {
        guard !busy else { return }
        guard accounts.current != nil else {
            accounts.isLoginPresented = true
            return
        }
        let comment = route.comment
        let target = !CommentLikes.shared.liked(comment)
        // Disabling the focused button would throw focus away: ignore presses while the request runs instead.
        busy = true
        Task {
            defer { busy = false }
            do {
                try await API.likeComment(aid: route.aid, rpid: comment.id, like: target)
                withAnimation(Theme.motion) { CommentLikes.shared.set(comment, liked: target) }
            } catch {
                AppNotice.shared.show("点赞失败：\(error.localizedDescription)")
            }
        }
    }
}

/// A reply in the thread. Focusable so the remote can move through (and scroll) a long thread.
private struct ReplyCard: View {
    let comment: Comment
    @FocusState private var focused: Bool

    var body: some View {
        CommentCard(comment: comment, lineLimit: 12, messageFont: Theme.Font.meta)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(.white.opacity(focused ? 0.7 : 0), lineWidth: 3))
            .scaleEffect(focused ? 1.03 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 10)
            .animation(Theme.motion, value: focused)
            .focusable()
            .focused($focused)
    }
}

extension Comment {
    /// "3小时前" for recent ones, a date otherwise ("2807天前" is hard to read).
    var displayTime: String {
        time > 0 ? Theme.relativeDate(time) : timeText.replacingOccurrences(of: "发布", with: "")
    }
}
