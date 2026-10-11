import BiliKit
import SwiftUI

/// 搜索: the system tvOS search keyboard, trending searches when empty, results by kind.
struct SearchView: View {
    @State private var query = ""
    @State private var submitted = ""
    @State private var kind: API.SearchKind = .video
    @State private var hot: [String] = []

    private let kinds: [API.SearchKind] = API.SearchKind.allCases

    var body: some View {
        VStack(spacing: 0) {
            if submitted.isEmpty {
                trending
            } else {
                ChipRow(items: kinds, selection: $kind) { Text($0.title) }
                results.id("\(submitted)|\(kind.rawValue)")
            }
        }
        .ambient("")
        .searchable(text: $query, prompt: "搜索视频、番剧、UP 主")
        .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespaces) }
        .task(id: query) {
            // Search as you type once there are 2+ characters and typing pauses (the tvOS keyboard is slow,
            // and every search is a risk-controlled request). Submitting searches immediately.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            let q = query.trimmingCharacters(in: .whitespaces)
            if !Task.isCancelled, q.count >= 2, q != submitted { submitted = q }
            if q.isEmpty { submitted = "" }
        }
        .task { hot = (try? await API.hotSearch()) ?? [] }
    }

    private var trending: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if !hot.isEmpty {
                    SectionHeader(title: "大家都在搜", subtitle: "选一个直接搜索")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible(), spacing: Theme.Spacing.m)],
                              spacing: Theme.Spacing.s)
                    {
                        ForEach(Array(hot.enumerated()), id: \.offset) { i, word in
                            Button {
                                query = word
                                submitted = word
                            } label: {
                                HStack(spacing: Theme.Spacing.m) {
                                    Text(verbatim: "\(i + 1)")
                                        .font(Theme.Font.numeral(40))
                                        .foregroundStyle(i < 3 ? Theme.accent : Theme.textTertiary)
                                        .fixedSize()
                                        .frame(width: 64, alignment: .trailing)
                                    Text(word).font(Theme.Font.body).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.card))
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.vertical, Theme.Spacing.l)
            .focusSection()
        }
    }

    @ViewBuilder
    private var results: some View {
        let q = submitted
        switch kind {
        case .video:
            VideoGrid(emptyMessage: "没有找到相关视频") { page in try await API.searchVideos(q, page: page) }
        case .bangumi, .movie:
            let k = kind
            PagedGrid(columns: 6, aspect: 3 / 4, emptyMessage: "没有找到相关\(k.title)") { page in
                let r = try await API.search(q, kind: k, page: page)
                return (r.results.map(API.seasonItem(fromSearch:)), r.hasMore)
            } card: { PosterCard(item: $0) }
        case .user:
            PagedGrid(columns: 5, aspect: 1, emptyMessage: "没有找到相关 UP 主") { page in
                let r = try await API.search(q, kind: .user, page: page)
                return (r.results.map(API.userItem(fromSearch:)), r.hasMore)
            } card: { UserCard(user: $0) }
        case .live:
            PagedGrid(emptyMessage: "没有找到相关直播") { page in
                let r = try await API.search(q, kind: .live, page: page)
                return (r.results.map(API.liveRoom(fromSearch:)), r.hasMore)
            } card: { LiveRoomCard(room: $0) }
        }
    }
}
