import BiliKit

/// What an item plays: the request (its ids are what progress is saved under) and, for 互动视频, the story module.
struct PlaybackTarget {
    var request: PlayRequest
    var story: StorySession?
}

typealias PlayerPhase = PlaybackPhase<PlaybackTarget>
