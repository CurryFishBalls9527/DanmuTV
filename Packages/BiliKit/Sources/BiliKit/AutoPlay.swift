import Foundation

/// 播完自动播放相关推荐: the next video after one ends.
public enum AutoPlay {
    /// First related video that isn't live, isn't the current one, and wasn't played in this session.
    public static func next(after bvid: String, related: [VideoItem], played: Set<String>) -> VideoItem? {
        related.first { $0.liveRoomID == 0 && !$0.bvid.isEmpty && $0.bvid != bvid && !played.contains($0.bvid) }
    }
}
