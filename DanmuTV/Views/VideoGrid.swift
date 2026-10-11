import BiliKit
import SwiftUI

/// Paged grid with skeleton / empty / error states, infinite scroll and refresh triggers
/// (Play/Pause inside the grid, tab re-select, account switch, optional auto-refresh).
struct PagedGrid<Item: Identifiable & Sendable, Card: View, Header: View>: View {
    @State private var model: PagedModel<Item>
    @Environment(\.tabReselectCount) private var tabReselectCount
    private let columns: Int
    private let aspect: CGFloat
    private let autoRefresh: Bool
    private let emptyMessage: String
    private let header: Header
    /// Card for an item and its position in the whole list (ranks).
    private let card: (Item, Int) -> Card
    /// The first `leadCount` items that pass `isLead` are handed to `lead` (a stage, a podium) instead of
    /// the grid; the rest keep their place (and index) in the grid.
    private let leadCount: Int
    private let isLead: ((Item) -> Bool)?
    private let lead: (([Item]) -> AnyView)?
    /// Shown instead of the grid skeleton while the first page loads (e.g. a stage skeleton).
    private let skeleton: AnyView?
    /// Content starts under the tab bar (pages that open on a stage).
    private let topBleed: Bool
    /// Changing this refreshes in place (e.g. a sort order read by `fetch`), keeping the header and its focus.
    private let refreshKey: AnyHashable?
    /// Cards offer 不感兴趣, which drops them from this grid (the home feed).
    private let dislikes: Bool

    init(columns: Int = 4, aspect: CGFloat = 16 / 9, autoRefresh: Bool = false, emptyMessage: String = "这里还什么都没有",
         refreshKey: AnyHashable? = nil, leadCount: Int = 0, isLead: ((Item) -> Bool)? = nil, lead: (([Item]) -> AnyView)? = nil,
         skeleton: AnyView? = nil, topBleed: Bool = false, dislikes: Bool = false,
         fetch: @escaping PagedModel<Item>.Fetcher, @ViewBuilder header: () -> Header, @ViewBuilder rankedCard: @escaping (Item, Int) -> Card)
    {
        _model = State(initialValue: PagedModel(fetch: fetch))
        self.dislikes = dislikes
        self.refreshKey = refreshKey
        self.leadCount = lead == nil ? 0 : leadCount
        self.isLead = isLead
        self.lead = lead
        self.skeleton = skeleton
        self.topBleed = topBleed
        self.columns = columns
        self.aspect = aspect
        self.autoRefresh = autoRefresh
        self.emptyMessage = emptyMessage
        self.header = header()
        card = rankedCard
    }

    init(columns: Int = 4, aspect: CGFloat = 16 / 9, autoRefresh: Bool = false, emptyMessage: String = "这里还什么都没有",
         refreshKey: AnyHashable? = nil, leadCount: Int = 0, isLead: ((Item) -> Bool)? = nil, lead: (([Item]) -> AnyView)? = nil,
         skeleton: AnyView? = nil, topBleed: Bool = false, dislikes: Bool = false,
         fetch: @escaping PagedModel<Item>.Fetcher, @ViewBuilder header: () -> Header, @ViewBuilder card: @escaping (Item) -> Card)
    {
        self.init(columns: columns, aspect: aspect, autoRefresh: autoRefresh, emptyMessage: emptyMessage, refreshKey: refreshKey,
                  leadCount: leadCount, isLead: isLead, lead: lead, skeleton: skeleton, topBleed: topBleed, dislikes: dislikes,
                  fetch: fetch, header: header,
                  rankedCard: { item, _ in card(item) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            scroll
            .environment(\.scrollToTop, ScrollToTopAction { withAnimation(Theme.crossfade) { proxy.scrollTo("top", anchor: .top) } })
            .onChange(of: model.generation) {
                proxy.scrollTo("top", anchor: .top)
            }
        }
        .onChange(of: tabReselectCount) {
            Task { await model.refresh() }
        }
        .onChange(of: refreshKey) {
            Task { await model.refresh() }
        }
        .onPlayPauseCommand {
            Task { await model.refresh() }
        }
        .task { await model.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .autoRefresh)) { _ in
            if autoRefresh { Task { await model.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountChanged)) { _ in
            Task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var scroll: some View {
        let scroll = ScrollView {
            header
                .id("top")
            content
                .padding(.bottom, 60)
        }
        if topBleed {
            // Clip off so stage artwork can overhang the horizontal safe area.
            scroll.ignoresSafeArea(edges: .top).scrollClipDisabled()
        } else {
            scroll
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            if let skeleton {
                skeleton
            } else {
                SkeletonGrid(columns: columns, aspect: aspect).padding(.horizontal, Theme.pagePadding)
            }
        case let .failed(message):
            ErrorRetryView(message: message) { Task { await model.refresh() } }
        case .loaded:
            if model.items.isEmpty {
                EmptyStateView(message: emptyMessage) { Task { await model.refresh() } }
            } else {
                VStack(spacing: Theme.Spacing.l) {
                    if let message = model.refreshError {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("刷新失败：\(message)（点按重试）", systemImage: "exclamationmark.triangle")
                                .font(Theme.Font.caption)
                        }
                        .buttonBorderShape(.capsule)
                    }
                    let (leadItems, rest) = split(model.items)
                    if let lead, !leadItems.isEmpty {
                        lead(leadItems)
                    }
                    FocusableGrid(items: rest, id: \.element.id, columns: columns) { entry in
                        card(entry.element, entry.offset)
                            .task { await model.loadMoreIfNeeded(current: entry.element) }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .environment(\.dislike, dislikeAction)
                    .padding(.top, lead == nil ? 0 : Theme.Spacing.s)
                    footer
                }
            }
        }
    }

    private var dislikeAction: DislikeAction? {
        guard dislikes else { return nil }
        return DislikeAction { [model] video in
            if let id = video.id as? Item.ID { withAnimation(Theme.motion) { model.remove(id: id) } }
        }
    }

    /// Lead items, and the grid items with their index in the whole list.
    private func split(_ items: [Item]) -> ([Item], [(offset: Int, element: Item)]) {
        guard leadCount > 0 else { return ([], Array(items.enumerated())) }
        var lead: [Item] = []
        var rest: [(offset: Int, element: Item)] = []
        for (index, item) in items.enumerated() {
            if lead.count < leadCount, isLead?(item) ?? true {
                lead.append(item)
            } else {
                rest.append((index, item))
            }
        }
        return (lead, rest)
    }

    @ViewBuilder
    private var footer: some View {
        if let message = model.loadMoreError {
            Button {
                Task { await model.loadMore() }
            } label: {
                Label("加载失败：\(message)（点按重试）", systemImage: "arrow.clockwise")
            }
            .buttonBorderShape(.capsule)
        } else if model.isLoadingMore {
            ProgressView()
        }
    }
}

extension PagedGrid where Header == EmptyView {
    init(columns: Int = 4, aspect: CGFloat = 16 / 9, autoRefresh: Bool = false, emptyMessage: String = "这里还什么都没有",
         fetch: @escaping PagedModel<Item>.Fetcher, @ViewBuilder card: @escaping (Item) -> Card)
    {
        self.init(columns: columns, aspect: aspect, autoRefresh: autoRefresh, emptyMessage: emptyMessage, fetch: fetch, header: { EmptyView() }, card: card)
    }
}

/// The common case: a grid of videos.
struct VideoGrid<Header: View>: View {
    private let grid: PagedGrid<VideoItem, VideoCard, Header>

    /// `stage`: the first videos open the page on a stage carrying `label` (e.g. 为你推荐), and the grid
    /// below is headed `gridTitle`; `shelves` is placed between the two.
    init(autoRefresh: Bool = false, emptyMessage: String = "这里还什么都没有", stage: (label: String, gridTitle: String)? = nil,
         shelves: (() -> AnyView)? = nil, dislikes: Bool = false, fetch: @escaping PageFetcher, @ViewBuilder header: () -> Header)
    {
        let lead: (([VideoItem]) -> AnyView)? = stage.map { stage in
            { items in AnyView(VideoStage(items: items, label: stage.label, gridTitle: stage.gridTitle, shelves: shelves)) }
        }
        // Live rooms have no detail page to open, so they stay in the grid.
        grid = PagedGrid(autoRefresh: autoRefresh, emptyMessage: emptyMessage, leadCount: 5, isLead: { $0.liveRoomID == 0 }, lead: lead,
                         skeleton: stage == nil ? nil : AnyView(VStack(spacing: Theme.Spacing.l) {
                             SkeletonStage()
                             SkeletonGrid().padding(.horizontal, Theme.pagePadding)
                         }), topBleed: stage != nil, dislikes: dislikes, fetch: fetch, header: header) { VideoCard(item: $0) }
    }

    var body: some View { grid }
}

extension VideoGrid where Header == EmptyView {
    init(autoRefresh: Bool = false, emptyMessage: String = "这里还什么都没有", stage: (label: String, gridTitle: String)? = nil,
         shelves: (() -> AnyView)? = nil, dislikes: Bool = false, fetch: @escaping PageFetcher)
    {
        self.init(autoRefresh: autoRefresh, emptyMessage: emptyMessage, stage: stage, shelves: shelves, dislikes: dislikes, fetch: fetch) { EmptyView() }
    }
}

/// The lead videos of a page on the stage, then optional shelves and the heading of the grid below.
struct VideoStage: View {
    let items: [VideoItem]
    let label: String
    let gridTitle: String
    var shelves: (() -> AnyView)?

    var body: some View {
        // Zero spacing: shelves that have nothing to show take no room.
        VStack(alignment: .leading, spacing: 0) {
            Stage(entries: items.map { Self.entry($0, label: label) }) { entry in
                PlayerLauncher.playVideo(bvid: entry.value.bvid, aid: entry.value.aid)
            }
            if let shelves { shelves() }
            SectionHeader(title: gridTitle).padding(.top, Theme.Spacing.section)
        }
    }

    static func entry(_ item: VideoItem, label: String) -> StageEntry<VideoItem> {
        var parts = [item.ownerName]
        if item.views > 0 { parts.append("\(BiliText.formatCount(item.views)) 播放") }
        if item.duration > 0 { parts.append(BiliText.formatDuration(item.duration)) }
        return StageEntry(id: item.id, cover: item.cover, label: label, title: item.title,
                          subtitle: parts.filter { !$0.isEmpty }.joined(separator: "    "), avatar: item.ownerFace, value: item)
    }
}

/// A card grid whose first rows are built eagerly. A lazy grid has no cells until they scroll into view,
/// so when it starts just below the screen (under a shelf) the focus engine finds nothing below and
/// Down gets stuck; with real cells there, focus moves and the page scrolls to them.
struct FocusableGrid<Element, ID: Hashable, Cell: View>: View {
    let items: [Element]
    let id: KeyPath<Element, ID>
    let columns: Int
    var eagerRows = 2
    @ViewBuilder let cell: (Element) -> Cell

    var body: some View {
        let eager = Array(items.prefix(columns * eagerRows))
        VStack(spacing: Theme.gridRowSpacing) {
            ForEach(Array(stride(from: 0, to: eager.count, by: columns)), id: \.self) { start in
                let row = eager[start ..< min(start + columns, eager.count)]
                HStack(alignment: .top, spacing: Theme.gridSpacing) {
                    ForEach(row, id: id) { cell($0).frame(maxWidth: .infinity) }
                    ForEach(0 ..< columns - row.count, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
            if items.count > eager.count {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gridSpacing, alignment: .top), count: columns),
                          spacing: Theme.gridRowSpacing)
                {
                    ForEach(items[eager.count...], id: id) { cell($0) }
                }
            }
        }
    }
}
