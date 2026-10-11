import BiliKit
import TVServices

/// Keeps the Top Shelf extension's 继续观看 row in step with the account's history.
@MainActor
enum TopShelf {
    private static var last: [ContinueWatchingShelf.Entry]?

    static func update(_ entries: [ContinueWatchingShelf.Entry]) {
        guard entries != last else { return }
        last = entries
        ContinueWatchingShelf.save(entries)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
