import BiliKit
import SwiftUI

struct VideoDetailView: View {
    let item: VideoItem

    var body: some View {
        // Popular/ranking/favourites can contain PGC episodes: open those as a season.
        if item.epID > 0 {
            SeasonDetailView(route: SeasonRoute(epID: item.epID))
        } else {
            UGCDetailView(item: item)
        }
    }
}

/// The cover fills the top-right of the screen and dissolves into the backdrop; title, uploader and the
/// one primary action sit on the dark ground to its left. Pages / collection / related follow as shelves.
private struct UGCDetailView: View {
    let item: VideoItem

    @State private var detail: VideoDetail?
    @State private var related: [VideoItem] = []
    @State private var tags: [String] = []
    @State private var error: String?
    @State private var actions: VideoActions?
    @FocusState private var playFocused: Bool

    var body: some View {
        let cover = detail?.item.cover ?? item.cover
        ScrollView {
            ZStack(alignment: .topLeading) {
                StageArtwork(url: cover)
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    hero
                    if let detail, detail.pages.count > 1 { pagesShelf(detail) }
                    if let collection = detail?.collection, collection.items.count > 1 { collectionShelf(collection) }
                    if !related.isEmpty {
                        Shelf(title: "相关推荐") {
                            ForEach(related) { VideoCard(item: $0).frame(width: Theme.videoCardWidth) }
                        }
                    }
                    if let detail, !detail.isPartial {
                        CommentsShelf(aid: detail.item.aid > 0 ? detail.item.aid : (BVID.aid(from: detail.item.bvid) ?? 0), title: detail.item.title)
                    }
                }
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollClipDisabled()
        .ambient(cover)
        .defaultFocus($playFocused, true)
        // Load once: returning from a related video or the UP page keeps focus and scroll position.
        .task(id: item.id) { if detail == nil { await load() } }
    }

    // MARK: Hero

    private var hero: some View {
        let shown = detail?.item ?? item
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if shown.ownerMid > 0 {
                NavigationLink(value: UserRoute(mid: shown.ownerMid, name: shown.ownerName)) {
                    HStack(spacing: 14) {
                        Avatar(url: shown.ownerFace, size: 56)
                        Text(shown.ownerName).font(Theme.Font.headline)
                        Image(systemName: "chevron.right").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.borderless)
            }

            Text(shown.title)
                .font(Theme.Font.hero)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)

            metadata(shown)

            if let detail, detail.isPartial {
                Label("详情暂时无法加载（B 站风控限制），仍可正常播放", systemImage: "exclamationmark.shield")
                    .font(Theme.Font.caption).foregroundStyle(.orange)
            } else if let detail {
                if detail.isChargeOnly {
                    Label("充电专属视频：需要为 UP 主充电后才能观看完整内容", systemImage: "bolt.fill")
                        .font(Theme.Font.meta).foregroundStyle(.orange)
                }
                if !detail.desc.isEmpty {
                    Text(detail.desc).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
                if !tags.isEmpty {
                    Text(tags.prefix(6).map { "#\($0)" }.joined(separator: "  "))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Button("重试") { Task { await load() } }.buttonBorderShape(.capsule)
            }

            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                PrimaryButton(title: "播放", systemImage: "play.fill") { play(pageIndex: 0, resumeLastPage: true) }
                    .focused($playFocused)
                if let actions, detail?.isPartial != true {
                    VideoActionRow(actions: actions, shareURL: API.shareURL(bvid: shown.bvid))
                }
            }
            .padding(.top, Theme.Spacing.s)
        }
        .frame(maxWidth: 1080, alignment: .leading)
        .frame(minHeight: Theme.stageHeight - 60, alignment: .bottomLeading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 140)
        .focusSection()
    }

    private func metadata(_ v: VideoItem) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            if v.views > 0 { Label(BiliText.formatCount(v.views), systemImage: "play.fill") }
            if v.danmaku > 0 { Label(BiliText.formatCount(v.danmaku), systemImage: "text.bubble.fill") }
            if let detail, detail.likes > 0 { Label(BiliText.formatCount(detail.likes), systemImage: "hand.thumbsup.fill") }
            if v.pubdate > 0 { Text(Theme.relativeDate(v.pubdate)) }
            if v.duration > 0 { Text(BiliText.formatDuration(v.duration)) }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Shelves

    private func pagesShelf(_ detail: VideoDetail) -> some View {
        Shelf(title: "选集", subtitle: "共 \(detail.pages.count) P") {
            ForEach(Array(detail.pages.enumerated()), id: \.element.id) { index, page in
                Button {
                    play(pageIndex: index)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("P\(page.page)").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(page.part).font(Theme.Font.card).lineLimit(2, reservesSpace: true)
                    }
                    .frame(width: 320, alignment: .topLeading)
                    .padding(8)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.card))
            }
        }
    }

    private func collectionShelf(_ collection: (title: String, items: [VideoItem])) -> some View {
        let bvid = detail?.item.bvid ?? item.bvid
        let current = collection.items.firstIndex { $0.bvid == bvid }
        // Opens at the current video.
        return Shelf(title: "合集 · \(collection.title)", subtitle: current.map { "第 \($0 + 1) / \(collection.items.count) 个" },
                     initialItem: current.map { AnyHashable(collection.items[$0].id) })
        {
            ForEach(collection.items) { v in
                VideoCard(item: v).frame(width: Theme.videoCardWidth).id(v.id)
            }
        }
    }

    // MARK: Data

    private func load() async {
        error = nil
        do {
            var d = item.bvid.isEmpty ? try await API.videoDetail(aid: item.aid) : try await API.videoDetail(bvid: item.bvid)
            if d.isPartial, !item.title.isEmpty {
                // The fallback only knows pages; keep what the card already showed.
                var merged = item
                merged.cid = d.item.cid
                merged.duration = d.item.duration
                d.item = merged
            }
            detail = d
            actions = VideoActions(aid: d.item.aid, bvid: d.item.bvid, ownerMid: d.item.ownerMid, copyright: d.copyright)
            playFocused = true
            let bvid = d.item.bvid
            async let relatedTask = (try? await API.related(bvid: bvid)) ?? []
            async let tagsTask = (try? await API.tags(bvid: bvid)) ?? []
            (related, tags) = await (relatedTask, tagsTask)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(pageIndex: Int, resumeLastPage: Bool = false) {
        guard let detail else { return }
        // Charge-only videos are still attempted (the user may have paid); the player
        // explains instead of showing a raw error if the stream is refused.
        PlayerLauncher.play(PlayRequest(detail: detail, pageIndex: pageIndex, resumeLastPage: resumeLastPage))
    }
}
