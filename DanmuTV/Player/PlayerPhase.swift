import BiliKit

/// What an item plays: the request (its ids are what progress is saved under) and, for 互动视频, the story module.
struct PlaybackTarget {
    var request: PlayRequest
    var story: StorySession?
    var fallbacks = PlaybackFallbacks()
}

typealias PlayerPhase = PlaybackPhase<PlaybackTarget>

/// What already failed on a page, avoided when it reloads (HDR 播放失败时自动降级 and friends).
struct PlaybackFallbacks {
    /// A decode failure on HEVC/AV1: retry with AVC.
    var forceAVC = false
    /// An HDR/DV variant failed: retry in SDR.
    var hdrFailed = false
    /// Dolby/FLAC audio failed: retry with AAC.
    var audioFailed = false
    var recoveryAttempts = 0
}
