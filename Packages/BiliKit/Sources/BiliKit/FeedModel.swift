import Foundation
import Observation

public typealias PageFetcher = @MainActor (_ page: Int) async throws -> (items: [VideoItem], hasMore: Bool)
public typealias FeedModel = PagedModel<VideoItem>

/// Paged list state shared by every grid (videos, seasons, people, folders): refresh, infinite scroll, de-duplication.
///
/// Every refresh bumps a token; results from older refreshes or load-mores that finish late are
/// dropped, so overlapping refreshes (Play/Pause, account switch, auto-refresh) can't interleave pages.
@MainActor
@Observable
public final class PagedModel<Item: Identifiable & Sendable> {
    public typealias Fetcher = @MainActor (_ page: Int) async throws -> (items: [Item], hasMore: Bool)

    public enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    public private(set) var items: [Item] = []
    public private(set) var phase: Phase = .idle
    public private(set) var hasMore = true
    /// Bumped on every successful refresh so the grid can scroll back to the top.
    public private(set) var generation = 0
    /// Set when loading the next page failed; the grid shows a retry footer.
    public private(set) var loadMoreError: String?
    /// Set when a refresh failed but older items are still shown.
    public private(set) var refreshError: String?
    public private(set) var isLoadingMore = false

    /// How close to the end (in items) the next page starts loading.
    public var prefetchDistance = 8

    private let fetch: Fetcher
    private var nextPage = 1
    private var token = 0
    private var seen = Set<Item.ID>()

    public init(fetch: @escaping Fetcher) {
        self.fetch = fetch
    }

    public func loadIfNeeded() async {
        if phase == .idle { await refresh() }
    }

    public func refresh() async {
        token += 1
        let myToken = token
        isLoadingMore = false
        loadMoreError = nil
        refreshError = nil
        if items.isEmpty { phase = .loading }
        do {
            let result = try await fetch(1)
            guard myToken == token else { return }
            seen = []
            items = result.items.filter { seen.insert($0.id).inserted }
            hasMore = result.hasMore && !result.items.isEmpty
            nextPage = 2
            generation += 1
            phase = .loaded
        } catch {
            guard myToken == token else { return }
            if BiliClient.isCancellation(error) {
                // e.g. the view disappeared mid-load: reload next time it appears.
                phase = items.isEmpty ? .idle : .loaded
            } else if items.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                refreshError = error.localizedDescription
                phase = .loaded
            }
        }
    }

    public func loadMoreIfNeeded(current item: Item) async {
        guard loadMoreError == nil,
              let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - prefetchDistance
        else { return }
        await loadMore()
    }

    /// Drops one item (e.g. 不感兴趣) without reloading; it won't come back from later pages either.
    public func remove(id: Item.ID) {
        items.removeAll { $0.id == id }
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore, phase == .loaded else { return }
        let myToken = token
        isLoadingMore = true
        loadMoreError = nil
        defer { if myToken == token { isLoadingMore = false } }
        do {
            let result = try await fetch(nextPage)
            guard myToken == token else { return }
            items.append(contentsOf: result.items.filter { seen.insert($0.id).inserted })
            hasMore = result.hasMore && !result.items.isEmpty
            nextPage += 1
        } catch {
            guard myToken == token, !BiliClient.isCancellation(error) else { return }
            loadMoreError = error.localizedDescription
        }
    }
}
