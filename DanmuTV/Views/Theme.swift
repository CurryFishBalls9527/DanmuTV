import BiliKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI

/// Design system. The picture is the interface: pages sit on near-black ink, and the artwork of whatever
/// is focused tints the whole screen (`AmbientBackdrop`, one pre-blurred layer per screen). Chrome stays
/// quiet until focused; Bilibili pink is reserved for the one primary action and for selection.
enum Theme {
    // MARK: Colour

    static let accent = Color(red: 0.984, green: 0.447, blue: 0.600) // #FB7299
    static let accentDeep = Color(red: 0.62, green: 0.16, blue: 0.36)
    static let vipGold = Color(red: 0.98, green: 0.76, blue: 0.33)
    static let live = Color(red: 1.0, green: 0.36, blue: 0.36)
    /// The page itself. Slightly blue so warm artwork reads warmer against it.
    static let base = Color(red: 0.039, green: 0.043, blue: 0.063)
    /// Translucent dark scrim behind text that sits on artwork (duration tags, viewer counts).
    static let scrim = Color.black.opacity(0.55)
    /// Tonal layers over the base.
    static let surface = Color.white.opacity(0.07)
    static let surfaceRaised = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.14)
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.42)

    // MARK: Type scale (fixed sizes: tvOS has no Dynamic Type, and these are tuned for 10 ft)

    enum Font {
        /// Title on the home / 番剧 stage.
        static let display = SwiftUI.Font.system(size: 70, weight: .bold)
        /// Title of a detail page (video / season / UP 主).
        static let hero = SwiftUI.Font.system(size: 58, weight: .bold)
        static let title = SwiftUI.Font.system(size: 48, weight: .bold)
        /// Title of a pushed list page (历史记录, 本地播放 …).
        static let page = SwiftUI.Font.system(size: 44, weight: .bold)
        /// Shelf / section headers.
        static let section = SwiftUI.Font.system(size: 34, weight: .semibold)
        /// Buttons, emphasised labels, sheet titles.
        static let headline = SwiftUI.Font.system(size: 31, weight: .semibold)
        /// Descriptions, prompts.
        static let body = SwiftUI.Font.system(size: 29)
        /// Card titles.
        static let card = SwiftUI.Font.system(size: 26, weight: .medium)
        /// Secondary lines under cards and in hero metadata.
        static let meta = SwiftUI.Font.system(size: 23)
        /// Small captions, hints.
        static let caption = SwiftUI.Font.system(size: 21)
        /// Text inside badges and tags.
        static let badge = SwiftUI.Font.system(size: 20, weight: .semibold)
        /// Ranking numerals: the one flourish.
        static func numeral(_ size: CGFloat) -> SwiftUI.Font { .system(size: size, weight: .black, design: .rounded) }
    }

    // MARK: Spacing / shape

    enum Spacing {
        static let xs: CGFloat = 8
        static let s: CGFloat = 16
        static let m: CGFloat = 24
        static let l: CGFloat = 40
        static let xl: CGFloat = 56
        /// Between sections of a page.
        static let section: CGFloat = 64
    }

    enum Radius {
        static let tag: CGFloat = 8
        static let card: CGFloat = 18
        static let panel: CGFloat = 28
        static let hero: CGFloat = 36
    }

    static let pagePadding: CGFloat = 80
    static let gridSpacing: CGFloat = 48
    /// Vertical distance between grid rows (room for the focus lift plus two text lines).
    static let gridRowSpacing: CGFloat = 56
    static let cardCorner: CGFloat = Radius.card
    /// Height of the full-bleed stage at the top of home / 番剧 / detail pages.
    static let stageHeight: CGFloat = 760
    /// tvOS's horizontal safe-area inset: how far stage artwork must overhang scroll content to reach the edge.
    static let safeAreaBleed: CGFloat = 80

    /// Card widths used in shelves, so every row lines up the same way.
    static let videoCardWidth: CGFloat = 400
    static let posterCardWidth: CGFloat = 240
    static let personCardWidth: CGFloat = 260

    // MARK: Motion

    /// One animation for state changes (selection, toasts, appearing rows). Motion that answers a press.
    static let motion = Animation.snappy(duration: 0.3, extraBounce: 0)
    /// Artwork swaps (stage, backdrop).
    static let crossfade = Animation.easeInOut(duration: 0.55)

    /// "刚刚 / 3小时前 / 3天前 / 2025年3月1日".
    static func relativeDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let age = Date().timeIntervalSince(date)
        if age < 7 * 86400 {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.unitsStyle = .short
            return age < 60 ? "刚刚" : f.localizedString(for: date, relativeTo: Date())
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: date)
    }
}

// MARK: Navigation destinations

/// Opens a season page (by season or by episode).
struct SeasonRoute: Hashable {
    var seasonID: Int?
    var epID: Int?
}

struct UserRoute: Hashable {
    var mid: Int
    var name: String
}

/// Full lists pushed from a home shelf.
enum FeedRoute: Hashable {
    case popular
}

// MARK: Ambient backdrop

/// The artwork currently colouring the screen: set by whatever card is focused or page is open.
@MainActor
@Observable
final class Ambience {
    static let shared = Ambience()
    private(set) var cover = ""

    /// An empty cover fades the screen back to plain ink.
    func set(_ cover: String) {
        guard cover != self.cover else { return }
        self.cover = cover
    }
}

extension View {
    /// While `focused`, this artwork tints the whole screen.
    func ambient(_ cover: String, when focused: Bool) -> some View {
        onChange(of: focused) { _, now in
            if now { Ambience.shared.set(cover) }
        }
    }

    /// Tints the screen with this artwork whenever the page is shown (tabs and stack pages stay alive, so
    /// onAppear re-asserts it after a pop or a tab switch). An empty cover clears the tint.
    func ambient(_ cover: String) -> some View {
        onAppear { Ambience.shared.set(cover) }
            .onChange(of: cover) { _, now in Ambience.shared.set(now) }
    }
}

/// Builds the small, pre-blurred image the backdrop shows. Blurring once at 240 px and stretching the
/// result costs nothing per frame, unlike a live blur over the full screen.
enum AmbientArt {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 50
        return cache
    }()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func load(_ cover: String) async -> UIImage? {
        guard let url = BiliText.thumbnail(cover, width: 320, height: 180) else { return nil }
        let key = url.absoluteString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return nil }
        let job = Task.detached(priority: .utility) { Self.render(data) }
        let image = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private nonisolated static func render(_ data: Data) -> UIImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let input = CIImage(cgImage: cg)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 16
        let tone = CIFilter.colorControls()
        tone.inputImage = blur.outputImage
        tone.saturation = 1.4
        tone.brightness = -0.04
        guard let output = tone.outputImage?.cropped(to: input.extent),
              let result = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: result)
    }
}

/// Full-screen ground of every page: ink, then the ambient artwork, then a scrim that keeps the lower
/// half and the left column (where text lives) dark.
struct AmbientBackdrop: View {
    private let ambience = Ambience.shared
    @State private var image: UIImage?
    @State private var shown = ""

    var body: some View {
        // The image is an overlay of the base colour, so its arrival changes nothing about layout.
        Theme.base
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .opacity(0.55)
                        .id(shown)
                        .transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.1), location: 0),
                                       .init(color: .black.opacity(0.35), location: 0.45),
                                       .init(color: Theme.base.opacity(0.95), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                LinearGradient(colors: [Theme.base.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.9), value: shown)
        .task(id: ambience.cover) {
            let cover = ambience.cover
            if cover.isEmpty {
                image = nil
                shown = ""
                return
            }
            // Debounce: moving quickly across a row shouldn't decode every cover on the way.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let loaded = await AmbientArt.load(cover), !Task.isCancelled else { return }
            image = loaded
            shown = cover
        }
    }
}

// MARK: Artwork

struct CoverImage: View {
    let url: String
    var width: Int = 640
    var height: Int = 360

    var body: some View {
        AsyncImage(url: BiliText.thumbnail(url, width: width, height: height), transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.surface)
            }
        }
        .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
        .clipped()
    }
}

struct Avatar: View {
    let url: String
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: BiliText.thumbnail(url, width: Int(size * 2), height: Int(size * 2))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Theme.surfaceRaised)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Artwork that fills the top-right of a page and dissolves into the backdrop along its left and bottom
/// edges: the title and actions sit on dark ground while the picture stays uncovered.
struct StageArtwork: View {
    let url: String
    var width: CGFloat = 1320

    var body: some View {
        CoverImage(url: url, width: 1280, height: 720)
            .frame(width: width)
            // One mask: horizontal fade × vertical fade (dark under the tab bar, solid through the
            // middle, gone before the bottom edge), so the picture has no edge anywhere.
            .mask {
                // The two gradients combine between themselves (cheap); the picture is masked once.
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5)],
                               startPoint: .leading, endPoint: .trailing)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                               .init(color: .black, location: 0.4), .init(color: .clear, location: 0.97)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
            // Reaches the screen's right edge: the scroll content stops at the safe area, the picture shouldn't.
            .offset(x: Theme.safeAreaBleed)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .allowsHitTesting(false)
    }
}

/// Small coloured capsule: 直播中 / 会员 / 独家 / 27万点赞.
struct Badge: View {
    let text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(Theme.Font.badge)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Dark translucent tag drawn over artwork: duration, viewer count, item count.
struct OverlayTag: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Theme.Font.badge.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
        .foregroundStyle(.white)
    }
}

/// Dot + 直播中, the live marker used on every live surface.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.white).frame(width: 10, height: 10)
            Text("直播中")
        }
        .font(Theme.Font.badge)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.live, in: Capsule())
        .foregroundStyle(.white)
    }
}

/// Ranking numeral drawn over the corner of artwork; the top three carry the accent.
struct RankNumeral: View {
    let rank: Int
    var size: CGFloat = 96

    var body: some View {
        Text(verbatim: "\(rank)")
            .font(Theme.Font.numeral(size))
            .foregroundStyle(rank <= 3
                ? LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
            .padding(.leading, 18)
            .padding(.bottom, 2)
    }
}

// MARK: Cards

/// Metadata under a card: the title brightens when its card is focused.
private struct CardCaption<Content: View>: View {
    let title: String
    let isFocused: Bool
    var lines = 2
    @ViewBuilder let detail: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Font.card)
                .foregroundStyle(isFocused ? .white : Theme.textSecondary)
                .lineLimit(lines, reservesSpace: lines > 1)
            detail()
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 6)
        .animation(Theme.motion, value: isFocused)
    }
}

/// 16:9 video card: artwork lifts with the tvOS card effect, metadata below, screen tint on focus.
struct VideoCard: View {
    let item: VideoItem
    /// 0–1 watched, shown as a thin bar (history / continue watching).
    var progress: Double?
    /// Off on an uploader's own page, where every card would repeat the same name.
    var showsOwner = true
    /// Ranking position drawn over the artwork.
    var rank: Int?
    var numeralSize: CGFloat = 96
    @FocusState private var focused: Bool

    var body: some View {
        if item.liveRoomID > 0 {
            LiveRoomCard(room: LiveRoom(roomID: item.liveRoomID, title: item.title, cover: item.cover, uname: item.ownerName,
                                        face: item.ownerFace, online: item.views))
        } else {
            videoCard
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            NavigationLink(value: item) {
                CoverImage(url: item.cover)
                    .overlay(alignment: .bottomTrailing) {
                        if item.duration > 0 { OverlayTag(text: BiliText.formatDuration(item.duration)).padding(12) }
                    }
                    .overlay(alignment: .topLeading) {
                        if !item.badge.isEmpty { Badge(text: item.badge).padding(12) }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let rank { RankNumeral(rank: rank, size: numeralSize) }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0 { ProgressBar(progress: progress) }
                    }
            }
            .buttonStyle(.card)
            // The artwork's overlays alone would read as just "10:10" or "百万播放".
            .accessibilityLabel(accessibilityText)
            .modifier(VideoCardMenu(item: item, showsOwner: showsOwner))
            .focused($focused)
            .ambient(item.cover, when: focused)

            CardCaption(title: item.title, isFocused: focused) {
                HStack(spacing: 12) {
                    if showsOwner, !item.ownerName.isEmpty {
                        if !item.ownerFace.isEmpty { Avatar(url: item.ownerFace, size: 28) }
                        Text(item.ownerName).lineLimit(1)
                    }
                    if item.views > 0 {
                        Label(BiliText.formatCount(item.views), systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                    }
                    if !showsOwner, item.pubdate > 0 {
                        Text(Theme.relativeDate(item.pubdate)).fixedSize()
                    }
                }
            }
        }
    }
}

extension VideoCard {
    /// "标题、UP 主、10:10".
    var accessibilityText: String {
        [item.title, showsOwner ? item.ownerName : "", item.duration > 0 ? BiliText.formatDuration(item.duration) : ""]
            .filter { !$0.isEmpty }.joined(separator: "、")
    }
}

/// Thin watched-progress bar along the bottom edge of artwork.
struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

/// 3:4 poster for seasons (番剧 / 影视).
struct PosterCard: View {
    let item: SeasonItem
    var rank: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            NavigationLink(value: SeasonRoute(seasonID: item.seasonID)) {
                CoverImage(url: item.cover, width: 360, height: 480)
                    .overlay(alignment: .topTrailing) {
                        if !item.badge.isEmpty { Badge(text: item.badge, color: item.badge.contains("会员") ? Theme.vipGold : Theme.accent).padding(10) }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let rank { RankNumeral(rank: rank, size: 80) }
                    }
            }
            .buttonStyle(.card)
            .focused($focused)
            .ambient(item.horizontalCover.isEmpty ? item.cover : item.horizontalCover, when: focused)
            CardCaption(title: item.title, isFocused: focused, lines: 1) {
                Text(item.subtitle.isEmpty ? " " : item.subtitle).lineLimit(1)
            }
        }
    }
}

struct UserCard: View {
    let user: UserItem
    @FocusState private var focused: Bool

    var body: some View {
        NavigationLink(value: UserRoute(mid: user.mid, name: user.name)) {
            VStack(spacing: Theme.Spacing.s) {
                Avatar(url: user.face, size: 150)
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 2))
                Text(user.name).font(Theme.Font.card).lineLimit(1)
                Text(user.sign.isEmpty ? " " : user.sign).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
        .focused($focused)
        .ambient(user.face, when: focused)
    }
}

/// 16:9 live room card: opens the room directly.
struct LiveRoomCard: View {
    let room: LiveRoom
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button {
                LiveLauncher.open(room)
            } label: {
                CoverImage(url: room.cover)
                    .overlay(alignment: .topLeading) {
                        if room.isLive { LiveBadge().padding(12) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if room.online > 0 {
                            OverlayTag(text: BiliText.formatCount(room.online), systemImage: "person.2.fill").padding(12)
                        }
                    }
                    .opacity(room.isLive ? 1 : 0.5)
            }
            .buttonStyle(.card)
            .focused($focused)
            .ambient(room.cover, when: focused)
            CardCaption(title: room.title, isFocused: focused) {
                HStack(spacing: 12) {
                    Avatar(url: room.face, size: 28)
                    Text(room.uname).lineLimit(1)
                    if !room.area.isEmpty { Text(room.area).fixedSize() }
                }
            }
        }
    }
}

// MARK: Stage

/// One item on the stage: wide artwork, a short label, title, one line of context.
struct StageEntry<Value: Hashable>: Identifiable {
    var id: String
    var cover: String
    var label: String
    var title: String
    var subtitle: String
    var avatar = ""
    var value: Value
}

/// Scrolls the enclosing page back to its top; set by pages that host a `Stage`.
/// Always equal, so setting it never invalidates the views that read it.
struct ScrollToTopAction: Equatable {
    let run: () -> Void
    func callAsFunction() { run() }
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var scrollToTop: ScrollToTopAction?
}

/// The top of home / 番剧: one item fills the screen, its artwork dissolving into the backdrop, with the
/// page's primary action. The small strip on the right swaps the stage as focus moves over it.
struct Stage<Value: Hashable>: View {
    let entries: [StageEntry<Value>]
    var playTitle = "播放"
    let play: (StageEntry<Value>) -> Void

    private enum Focus: Hashable { case play, detail, strip(Int) }
    @Environment(\.scrollToTop) private var scrollToTop
    @State private var current = 0
    @FocusState private var focus: Focus?

    /// The entry on show; `current` may lag a shorter list for one update.
    private var shown: StageEntry<Value>? {
        entries.indices.contains(current) ? entries[current] : entries.first
    }

    var body: some View {
        if let entry = shown {
            stage(entry)
        }
    }

    private func stage(_ entry: StageEntry<Value>) -> some View {
        ZStack(alignment: .bottomLeading) {
            StageArtwork(url: entry.cover)
                .id(entry.id)
                .transition(.opacity)
                .frame(maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(entry.label)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.accent)
                    Text(entry.title)
                        .font(Theme.Font.display)
                        .tracking(-0.5)
                        .lineLimit(2, reservesSpace: true)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                    HStack(spacing: 14) {
                        if !entry.avatar.isEmpty { Avatar(url: entry.avatar, size: 44) }
                        Text(entry.subtitle).lineLimit(1)
                    }
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                }
                .id(entry.id)
                .transition(.opacity)

                HStack(spacing: Theme.Spacing.s) {
                    PrimaryButton(title: playTitle, systemImage: "play.fill") { play(entry) }
                        .focused($focus, equals: .play)
                    NavigationLink(value: entry.value) {
                        Label("详情", systemImage: "info.circle")
                            .font(Theme.Font.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 8)
                    }
                    .focused($focus, equals: .detail)
                }
                .padding(.top, Theme.Spacing.xs)
            }
            .frame(maxWidth: 1060, alignment: .leading)
            .padding(.leading, Theme.pagePadding)
            .padding(.bottom, Theme.Spacing.l)
        }
        // An overlay sized to the thumbnails: a full-width section would cover 播放/详情 and swallow focus.
        .overlay(alignment: .bottomTrailing) {
            if entries.count > 1 {
                HStack(spacing: 14) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        NavigationLink(value: e.value) {
                            CoverImage(url: e.cover, width: 320, height: 180)
                                .frame(width: 176)
                                .overlay {
                                    if i == current {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent, lineWidth: 4)
                                    }
                                }
                                .opacity(i == current ? 1 : 0.7)
                        }
                        .buttonStyle(.card)
                        .accessibilityLabel(e.title)
                        .focused($focus, equals: .strip(i))
                    }
                }
                .padding(.trailing, Theme.pagePadding)
                .padding(.bottom, Theme.Spacing.l + 4)
                .focusSection()
            }
        }
        .frame(height: Theme.stageHeight)
        .frame(maxWidth: .infinity)
        .animation(Theme.crossfade, value: current)
        .defaultFocus($focus, .play)
        .focusSection()
        .onChange(of: focus) { before, now in
            // Arriving from outside (tab bar, shelves): the focus engine picks by geometry, often the strip
            // or 详情. Entering the stage always starts on 播放 (defaultFocus alone isn't honoured here).
            if before == nil, now != nil {
                // Fully scrolled back, or Up from 播放 has nothing to move to and never reaches the tab bar.
                scrollToTop?()
                if now != .play {
                    focus = .play
                    return
                }
            }
            if case let .strip(i) = now, entries.indices.contains(i) { current = i }
            if now != nil, let cover = shown?.cover { Ambience.shared.set(cover) }
        }
        .onChange(of: current) { if let cover = shown?.cover { Ambience.shared.set(cover) } }
        // New entries (番剧 type switch, refresh): start over from the first.
        .onChange(of: entries.first?.id) {
            current = 0
            if let cover = shown?.cover { Ambience.shared.set(cover) }
        }
        .onAppear { Ambience.shared.set(entry.cover) }
    }
}

// MARK: Layout

/// Header of a shelf or section: title, optional subtitle, aligned to the page margin.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(title).font(Theme.Font.section)
            if let subtitle { Text(subtitle).font(Theme.Font.meta).foregroundStyle(Theme.textTertiary) }
        }
        .padding(.horizontal, Theme.pagePadding)
    }
}

/// Title of a pushed page (tvOS draws no navigation bar titles): big, with a one-line context.
struct PageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Font.page)
            if let subtitle, !subtitle.isEmpty { Text(subtitle).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.l)
    }
}

/// A titled horizontal row ("shelf") of focusable items.
struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Item id (`.id(...)` on a child) the row should open scrolled to, e.g. the current episode.
    var initialItem: AnyHashable?
    @ViewBuilder let content: () -> Content
    @State private var position: AnyHashable?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.gridSpacing) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, Theme.Spacing.m)
            }
            .scrollPosition(id: $position, anchor: .leading)
            .scrollClipDisabled()
            .onAppear { if position == nil { position = initialItem } }
        }
        .focusSection()
    }
}

/// Last card of a shelf: opens the full list. Being inside the row, it's reachable by swiping right
/// (a separate link below the row is easy to skip with the remote).
struct SeeAllCard<Value: Hashable>: View {
    let value: Value
    var title = "查看全部"
    var width: CGFloat = Theme.videoCardWidth
    var aspect: CGFloat = 16 / 9

    var body: some View {
        NavigationLink(value: value) {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 84, height: 84)
                    .background(Theme.surfaceRaised, in: Circle())
                Text(title).font(Theme.Font.card)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(width: width, height: width / aspect)
            .background(Theme.surface)
        }
        .buttonStyle(.card)
    }
}

/// A row of selectable chips (categories, kinds, sort orders). One focus section, scrolls when long.
struct ChipRow<Item: Identifiable & Equatable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item
    /// Space before the first chip; the page margin unless the row follows a header on the same line.
    var leadingInset: CGFloat = Theme.pagePadding
    /// The selected chip is where focus lands when the page opens.
    var focusesByDefault = false
    @ViewBuilder let label: (Item) -> Label
    @FocusState private var focused: Item.ID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    FilterChip(isSelected: item == selection) {
                        withAnimation(Theme.motion) { selection = item }
                    } label: {
                        label(item)
                    }
                    .focused($focused, equals: item.id)
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, Theme.pagePadding)
            .padding(.vertical, Theme.Spacing.m)
        }
        .scrollClipDisabled()
        .focusSection()
        .defaultFocus($focused, selection.id, priority: focusesByDefault ? .userInitiated : .automatic)
    }
}

/// One chip: pink when selected, quiet otherwise; the system focus ring on top.
struct FilterChip<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 26, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, -2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(isSelected ? Theme.accent : nil)
    }
}

/// The page's one primary action: a wide pink pill (播放 / 扫码登录 …).
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(Theme.Font.headline)
            .padding(.horizontal, 40)
            .padding(.vertical, 8)
        }
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
    }
}

/// Round icon button with a caption under it (点赞 / 投币 / 收藏…). Highlighted when active. The caption
/// is part of the button's label, so modifiers at the call site (sheets, menus, disabled) reach the button.
struct ActionButton: View {
    let title: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionButtonLabel(title: title, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(ActionButtonStyle())
    }
}

/// Only the disc responds to focus (white, lifted); the caption stays put, like the system's own circles.
private struct ActionButtonLabel: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .symbolVariant(isOn ? .fill : .none)
                .foregroundStyle(isOn ? Theme.accent : (focused ? Color.black : .white))
                .frame(width: 92, height: 92)
                .background(focused ? Color.white : Theme.surfaceRaised, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: focused ? 0 : 1))
                .scaleEffect(focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 14)
            Text(title).font(Theme.Font.caption).foregroundStyle(focused ? .white : Theme.textSecondary).lineLimit(1)
        }
        .frame(width: 120)
        .animation(Theme.motion, value: focused)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.motion, value: configuration.isPressed)
    }
}

/// Circular icon with a caption: the quick-access tiles on 我的 (添加账户 / 本地播放 / 设置).
struct IconTile: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .frame(width: 92, height: 92)
                .background(Theme.surfaceRaised, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(width: 170)
    }
}

// MARK: Loading / empty states

/// A light band sweeping across skeleton shapes while content loads.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: -geo.size.width * 0.5 + phase * geo.size.width * 1.5)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Grey placeholder cards shown while a grid's first page loads.
struct SkeletonGrid: View {
    var columns = 4
    var aspect: CGFloat = 16 / 9

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gridSpacing), count: columns), spacing: Theme.gridRowSpacing) {
            ForEach(0 ..< columns * 2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.surface).aspectRatio(aspect, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(height: 24)
                    RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(width: 160, height: 20)
                }
            }
        }
        .modifier(Shimmer())
        .accessibilityLabel("加载中")
    }
}

/// Placeholder for a stage while it loads: title lines and a play pill where they will appear.
struct SkeletonStage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface).frame(width: 180, height: 30)
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface).frame(width: 900, height: 72)
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface).frame(width: 600, height: 72)
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface).frame(width: 420, height: 30)
            Capsule().fill(Theme.surface).frame(width: 220, height: 76).padding(.top, 10)
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, Theme.Spacing.l)
        .frame(height: Theme.stageHeight, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Shimmer())
        .accessibilityLabel("加载中")
    }
}

/// Placeholder for a detail page while it loads: poster + title lines in the hero layout.
struct SkeletonHero: View {
    var posterAspect: CGFloat = 16 / 9
    var posterWidth: CGFloat = 620

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            if posterWidth > 0 {
                RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.surface)
                    .frame(width: posterWidth, height: posterWidth / posterAspect)
            }
            VStack(alignment: .leading, spacing: 20) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface).frame(width: 700, height: 56)
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface).frame(width: 320, height: 30)
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface).frame(width: 800, height: 26)
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface).frame(width: 600, height: 26)
                Capsule().fill(Theme.surface).frame(width: 220, height: 76).padding(.top, 10)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.pagePadding)
        .modifier(Shimmer())
        .accessibilityLabel("加载中")
    }
}

/// One layout for every "nothing to show" moment: a symbol in a soft disc, a title, a short reason,
/// and (when there is one) the action that fixes it.
struct StatePlaceholder: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 150, height: 150)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            Text(title).font(Theme.Font.headline)
            if let message, !message.isEmpty {
                Text(message)
                    .font(Theme.Font.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: 900)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonBorderShape(.capsule)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460)
        // Its own focus section: the button is reachable from the tab bar or any edge, not just straight below.
        .focusSection()
    }
}

struct ErrorRetryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        StatePlaceholder(systemImage: "wifi.exclamationmark", title: "加载失败", message: message, actionTitle: "重试", action: retry)
    }
}

struct EmptyStateView: View {
    let message: String
    var systemImage = "tray"
    var retry: (() -> Void)?

    var body: some View {
        StatePlaceholder(systemImage: systemImage, title: message, actionTitle: retry == nil ? nil : "刷新", action: retry)
    }
}

/// Shown on pages that need an account.
struct LoginPrompt: View {
    var message = "登录后查看"
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        StatePlaceholder(systemImage: "qrcode", title: message, message: "用哔哩哔哩手机 App 扫码即可登录",
                         actionTitle: "扫码登录") { accounts.isLoginPresented = true }
            .tint(Theme.accent)
    }
}

extension Notification.Name {
    /// Posted when the app returns to the foreground after `autoRefreshMinutes` in the background.
    static let autoRefresh = Notification.Name("DanmuTV.autoRefresh")
}
