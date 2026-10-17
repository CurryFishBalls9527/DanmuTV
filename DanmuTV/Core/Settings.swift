import BiliKit
import Foundation
import Observation

enum CodecPreference: String, CaseIterable, Identifiable {
    case hevc, avc, av1
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hevc: return "HEVC (H.265)"
        case .avc: return "AVC (H.264)"
        case .av1: return "AV1"
        }
    }

    /// Bilibili `codecid` values.
    var codecID: Int {
        switch self {
        case .avc: return 7
        case .hevc: return 12
        case .av1: return 13
        }
    }
}

enum CDNStrategy: String, CaseIterable, Identifiable {
    /// Use the URL Bilibili hands out.
    case none
    /// Swap MCDN/PCDN hosts (frequent cause of stalls) for an official upos mirror.
    case preferOfficial
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "不处理"
        case .preferOfficial: return "播放链接重写（切换到主 CDN）"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // Playback
    var defaultSpeed: Double { didSet { defaults.set(defaultSpeed, forKey: "defaultSpeed") } }
    var maxQuality: Int { didSet { defaults.set(maxQuality, forKey: "maxQuality") } }
    var codecPreference: CodecPreference { didSet { defaults.set(codecPreference.rawValue, forKey: "codecPreference") } }
    /// 仅加载最高分辨率: no bandwidth ladder, always the best allowed quality.
    var onlyHighestQuality: Bool { didSet { defaults.set(onlyHighestQuality, forKey: "onlyHighestQuality") } }
    var filterHighFramerate: Bool { didSet { defaults.set(filterHighFramerate, forKey: "filterHighFramerate") } }
    var enableHDR: Bool { didSet { defaults.set(enableHDR, forKey: "enableHDR") } }
    var enableDolbyAudio: Bool { didSet { defaults.set(enableDolbyAudio, forKey: "enableDolbyAudio") } }
    var displayMatchMode: DisplayMatchMode { didSet { defaults.set(displayMatchMode.rawValue, forKey: "displayMatchMode") } }
    /// 强制 SDR 输出: never switch the TV to HDR (avoids HDMI re-sync black screens).
    var forceSDR: Bool { didSet { defaults.set(forceSDR, forKey: "forceSDR") } }
    /// Fixed output refresh rate (e.g. 59.94); 0 = follow the content.
    var forcedRefreshRate: Double { didSet { defaults.set(forcedRefreshRate, forKey: "forcedRefreshRate") } }
    var enableDolbyVision: Bool { didSet { defaults.set(enableDolbyVision, forKey: "enableDolbyVision") } }
    var enableLosslessAudio: Bool { didSet { defaults.set(enableLosslessAudio, forKey: "enableLosslessAudio") } }
    /// nil = automatic (on when the IP is outside mainland China).
    var cdnPreferAkamai: Bool? {
        didSet {
            if let v = cdnPreferAkamai { defaults.set(v, forKey: "cdnPreferAkamai") } else { defaults.removeObject(forKey: "cdnPreferAkamai") }
        }
    }
    /// 强制替换线路 (preset or custom host); empty = off.
    var cdnRewriteHost: String { didSet { defaults.set(cdnRewriteHost, forKey: "cdnRewriteHost") } }
    var cdnBlacklist: [String] { didSet { defaults.set(cdnBlacklist, forKey: "cdnBlacklist") } }
    /// 快速加载模式: start on a mid-quality variant with a single route.
    var fastLoad: Bool { didSet { defaults.set(fastLoad, forKey: "fastLoad") } }
    var overseas: Bool { didSet { defaults.set(overseas, forKey: "overseas") } }
    var cdnStrategy: CDNStrategy { didSet { defaults.set(cdnStrategy.rawValue, forKey: "cdnStrategy") } }
    var autoPlayNext: Bool { didSet { defaults.set(autoPlayNext, forKey: "autoPlayNext") } }
    /// 播完自动播放相关推荐 (after a video's last part).
    var autoPlayRelated: Bool { didSet { defaults.set(autoPlayRelated, forKey: "autoPlayRelated") } }
    /// 投屏: show up in the official app's cast list while DanmuTV is open.
    var castEnabled: Bool { didSet { defaults.set(castEnabled, forKey: "castEnabled") } }
    /// 番剧自动跳过片头片尾.
    var autoSkipOPED: Bool { didSet { defaults.set(autoSkipOPED, forKey: "autoSkipOPED") } }
    var resumePlayback: Bool { didSet { defaults.set(resumePlayback, forKey: "resumePlayback") } }
    var showSubtitles: Bool { didSet { defaults.set(showSubtitles, forKey: "showSubtitles") } }

    // Danmaku
    var danmakuEnabled: Bool { didSet { defaults.set(danmakuEnabled, forKey: "danmakuEnabled") } }
    /// Danmaku with weight below this (0–11) are hidden. Bilibili's weight is its "smart filter" score.
    var danmakuMinWeight: Int { didSet { defaults.set(danmakuMinWeight, forKey: "danmakuMinWeight") } }
    var danmakuOpacity: Double { didSet { defaults.set(danmakuOpacity, forKey: "danmakuOpacity") } }
    var danmakuFontSize: Double { didSet { defaults.set(danmakuFontSize, forKey: "danmakuFontSize") } }
    /// Fraction of the screen height danmaku may occupy.
    var danmakuArea: Double { didSet { defaults.set(danmakuArea, forKey: "danmakuArea") } }
    /// Seconds a scrolling danmaku takes to cross the screen.
    var danmakuDuration: Double { didSet { defaults.set(danmakuDuration, forKey: "danmakuDuration") } }
    var danmakuShowScroll: Bool { didSet { defaults.set(danmakuShowScroll, forKey: "danmakuShowScroll") } }
    var danmakuShowTop: Bool { didSet { defaults.set(danmakuShowTop, forKey: "danmakuShowTop") } }
    var danmakuShowBottom: Bool { didSet { defaults.set(danmakuShowBottom, forKey: "danmakuShowBottom") } }
    var danmakuShowColored: Bool { didSet { defaults.set(danmakuShowColored, forKey: "danmakuShowColored") } }
    /// 0.25–1: share of comments shown.
    var danmakuDensity: Double { didSet { defaults.set(danmakuDensity, forKey: "danmakuDensity") } }
    /// 弹幕聚合: merge repeated comments and show a count.
    var danmakuMerge: Bool { didSet { defaults.set(danmakuMerge, forKey: "danmakuMerge") } }
    /// 智能防挡: on videos with a person mask, comments pass behind people.
    var danmakuMask: Bool { didSet { defaults.set(danmakuMask, forKey: "danmakuMask") } }
    /// 高能进度条: danmaku heat above the scrubber, and markers at the busiest moments.
    var heatBar: Bool { didSet { defaults.set(heatBar, forKey: "heatBar") } }
    /// Also apply the account's cloud block list.
    var danmakuSyncAccountFilter: Bool { didSet { defaults.set(danmakuSyncAccountFilter, forKey: "danmakuSyncAccountFilter") } }
    /// Turn on AI-generated subtitles automatically when a video has no human ones.
    var subtitleAIDefault: Bool { didSet { defaults.set(subtitleAIDefault, forKey: "subtitleAIDefault") } }
    /// Subtitle lines containing these (e.g. ads) are hidden.
    var subtitleBlockWords: [String] { didSet { defaults.set(subtitleBlockWords, forKey: "subtitleBlockWords") } }
    var danmakuBlockWords: [String] { didSet { defaults.set(danmakuBlockWords, forKey: "danmakuBlockWords") } }
    /// 直播强制使用 VLC 播放器 (FLV streams).
    var liveForceVLC: Bool { didSet { defaults.set(liveForceVLC, forKey: "liveForceVLC") } }
    /// 视频内广告 / 恰饭片段自动跳过 (community segment database; off by default).
    var skipSponsorSegments: Bool { didSet { defaults.set(skipSponsorSegments, forKey: "skipSponsorSegments") } }
    var liveShowSuperChat: Bool { didSet { defaults.set(liveShowSuperChat, forKey: "liveShowSuperChat") } }

    // General
    /// 热门 without login cookies.
    var popularAnonymous: Bool { didSet { defaults.set(popularAnonymous, forKey: "popularAnonymous") } }
    var hideDynamicTab: Bool { didSet { defaults.set(hideDynamicTab, forKey: "hideDynamicTab") } }
    /// Popular / ranking / dynamic refresh when returning after this many minutes in the background.
    var autoRefreshMinutes: Int { didSet { defaults.set(autoRefreshMinutes, forKey: "autoRefreshMinutes") } }
    var iCloudSync: Bool {
        didSet {
            defaults.set(iCloudSync, forKey: "iCloudSync")
            AccountStore.shared.syncSettingChanged()
        }
    }

    private init() {
        defaults.register(defaults: [
            "defaultSpeed": 1.0,
            "maxQuality": 0,
            "codecPreference": CodecPreference.hevc.rawValue,
            "filterHighFramerate": false,
            "onlyHighestQuality": false,
            "enableHDR": true,
            "enableDolbyAudio": true,
            "displayMatchMode": DisplayMatchMode.always.rawValue,
            "forceSDR": false,
            "forcedRefreshRate": 0.0,
            "enableDolbyVision": true,
            "enableLosslessAudio": true,
            "cdnRewriteHost": "",
            "cdnBlacklist": [String](),
            "fastLoad": false,
            "cdnStrategy": CDNStrategy.none.rawValue,
            "autoPlayNext": true,
            "autoPlayRelated": true,
            "castEnabled": true,
            "resumePlayback": true,
            "autoSkipOPED": true,
            "showSubtitles": true,
            "danmakuEnabled": true,
            "danmakuMinWeight": 0,
            "danmakuOpacity": 0.85,
            "danmakuFontSize": 42.0,
            "danmakuArea": 0.5,
            "danmakuDuration": 9.0,
            "danmakuShowScroll": true,
            "danmakuShowTop": true,
            "danmakuShowBottom": true,
            "danmakuShowColored": true,
            "danmakuDensity": 1.0,
            "danmakuMerge": true,
            "danmakuMask": true,
            "heatBar": true,
            "danmakuSyncAccountFilter": true,
            "subtitleAIDefault": false,
            "subtitleBlockWords": [String](),
            "danmakuBlockWords": [String](),
            "liveShowSuperChat": true,
            "liveForceVLC": false,
            "skipSponsorSegments": false,
            "iCloudSync": true,
            "popularAnonymous": false,
            "hideDynamicTab": false,
            "autoRefreshMinutes": 15,
        ])
        defaultSpeed = defaults.double(forKey: "defaultSpeed")
        maxQuality = defaults.integer(forKey: "maxQuality")
        codecPreference = CodecPreference(rawValue: defaults.string(forKey: "codecPreference") ?? "") ?? .hevc
        filterHighFramerate = defaults.bool(forKey: "filterHighFramerate")
        onlyHighestQuality = defaults.bool(forKey: "onlyHighestQuality")
        enableHDR = defaults.bool(forKey: "enableHDR")
        enableDolbyAudio = defaults.bool(forKey: "enableDolbyAudio")
        displayMatchMode = DisplayMatchMode(rawValue: defaults.string(forKey: "displayMatchMode") ?? "") ?? .always
        forceSDR = defaults.bool(forKey: "forceSDR")
        forcedRefreshRate = defaults.double(forKey: "forcedRefreshRate")
        enableDolbyVision = defaults.bool(forKey: "enableDolbyVision")
        enableLosslessAudio = defaults.bool(forKey: "enableLosslessAudio")
        cdnPreferAkamai = defaults.object(forKey: "cdnPreferAkamai") as? Bool
        cdnRewriteHost = defaults.string(forKey: "cdnRewriteHost") ?? ""
        cdnBlacklist = defaults.stringArray(forKey: "cdnBlacklist") ?? []
        fastLoad = defaults.bool(forKey: "fastLoad")
        overseas = defaults.bool(forKey: "overseas")
        cdnStrategy = CDNStrategy(rawValue: defaults.string(forKey: "cdnStrategy") ?? "") ?? .none
        autoPlayNext = defaults.bool(forKey: "autoPlayNext")
        autoPlayRelated = defaults.bool(forKey: "autoPlayRelated")
        castEnabled = defaults.bool(forKey: "castEnabled")
        resumePlayback = defaults.bool(forKey: "resumePlayback")
        autoSkipOPED = defaults.bool(forKey: "autoSkipOPED")
        showSubtitles = defaults.bool(forKey: "showSubtitles")
        danmakuEnabled = defaults.bool(forKey: "danmakuEnabled")
        danmakuMinWeight = defaults.integer(forKey: "danmakuMinWeight")
        danmakuOpacity = defaults.double(forKey: "danmakuOpacity")
        danmakuFontSize = defaults.double(forKey: "danmakuFontSize")
        danmakuArea = defaults.double(forKey: "danmakuArea")
        danmakuDuration = defaults.double(forKey: "danmakuDuration")
        danmakuShowScroll = defaults.bool(forKey: "danmakuShowScroll")
        danmakuShowTop = defaults.bool(forKey: "danmakuShowTop")
        danmakuShowBottom = defaults.bool(forKey: "danmakuShowBottom")
        danmakuShowColored = defaults.bool(forKey: "danmakuShowColored")
        danmakuDensity = defaults.double(forKey: "danmakuDensity")
        danmakuMerge = defaults.bool(forKey: "danmakuMerge")
        danmakuMask = defaults.bool(forKey: "danmakuMask")
        heatBar = defaults.bool(forKey: "heatBar")
        danmakuSyncAccountFilter = defaults.bool(forKey: "danmakuSyncAccountFilter")
        subtitleAIDefault = defaults.bool(forKey: "subtitleAIDefault")
        subtitleBlockWords = defaults.stringArray(forKey: "subtitleBlockWords") ?? []
        danmakuBlockWords = defaults.stringArray(forKey: "danmakuBlockWords") ?? []
        liveShowSuperChat = defaults.bool(forKey: "liveShowSuperChat")
        liveForceVLC = defaults.bool(forKey: "liveForceVLC")
        skipSponsorSegments = defaults.bool(forKey: "skipSponsorSegments")
        iCloudSync = defaults.bool(forKey: "iCloudSync")
        popularAnonymous = defaults.bool(forKey: "popularAnonymous")
        hideDynamicTab = defaults.bool(forKey: "hideDynamicTab")
        autoRefreshMinutes = defaults.integer(forKey: "autoRefreshMinutes")
    }
}

extension AppSettings {
    /// Whether the client is outside mainland China (last lookup, persisted so the first play
    /// after launch already uses it).
    static var isOverseas: Bool {
        get { shared.overseas }
        set { shared.overseas = newValue }
    }

    var cdnPolicy: CDNPolicy {
        CDNPolicy(preferOfficial: cdnStrategy == .preferOfficial,
                  preferAkamai: cdnPreferAkamai ?? Self.isOverseas,
                  rewriteHost: cdnRewriteHost.isEmpty ? nil : cdnRewriteHost,
                  blacklist: Set(cdnBlacklist.map { $0.lowercased() }))
    }
}
