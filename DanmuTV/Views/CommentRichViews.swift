import BiliKit
import SwiftUI
import UIKit

/// Emote images ([doge] …), fetched once per app run and shared by every comment showing them.
@MainActor
@Observable
final class EmoteStore {
    static let shared = EmoteStore()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var order: [String] = []
    private static let limit = 300

    func load(_ urls: [String]) {
        for url in Set(urls) where images[url] == nil && !loading.contains(url) {
            guard let u = BiliText.thumbnail(url, width: 96, height: 96) else { continue }
            loading.insert(url)
            Task {
                defer { loading.remove(url) }
                guard let (data, _) = try? await URLSession.shared.data(from: u), let image = UIImage(data: data) else { return }
                images[url] = image
                order.append(url)
                if order.count > Self.limit {
                    let old = order.removeFirst()
                    images[old] = nil
                    scaled[old] = nil
                }
            }
        }
    }

    @ObservationIgnored private var scaled: [String: [CGFloat: UIImage]] = [:]

    /// The emote redrawn at a line's height (Text can't resize an inline image); nil until it has loaded.
    func inline(_ url: String, height: CGFloat) -> UIImage? {
        guard let image = images[url] else { return nil }
        if let hit = scaled[url]?[height] { return hit }
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        let size = CGSize(width: (height * ratio).rounded(), height: height.rounded())
        let out = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        scaled[url, default: [:]][height] = out
        return out
    }
}

/// A comment's message with its emotes drawn inline at the text's size (as text until their image arrives).
struct CommentText: View {
    let comment: Comment
    var font: Font = Theme.Font.body
    /// Point size of `font`, for the emote images.
    var size: CGFloat = 29

    var body: some View {
        let segments = comment.segments
        let emoteURLs = segments.compactMap { if case let .emote(_, url) = $0 { url } else { nil } }
        segments.reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case let .text(s):
                return Text("\(text)\(Text(verbatim: s))")
            case let .emote(key, url):
                guard let image = EmoteStore.shared.inline(url, height: size * 1.3) else { return Text("\(text)\(Text(verbatim: key))") }
                let piece = Text(Image(uiImage: image)).baselineOffset(-size * 0.22)
                return Text("\(text)\(piece)")
            }
        }
        .font(font)
        .task(id: comment.id) {
            if !emoteURLs.isEmpty { EmoteStore.shared.load(emoteURLs) }
        }
    }
}

/// The comment's pictures under its text on the thread page; each opens full screen.
struct CommentPictureRow: View {
    let pictures: [CommentPicture]
    @State private var viewing: PictureSelection?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                ForEach(Array(pictures.enumerated()), id: \.offset) { i, picture in
                    Button {
                        viewing = PictureSelection(index: i)
                    } label: {
                        CoverImage(url: picture.url, width: 400, height: 400)
                            .frame(width: 260, height: 260)
                    }
                    .buttonStyle(.card)
                    .accessibilityLabel("图片 \(i + 1)")
                    .accessibilityIdentifier("comment.picture.\(i)")
                }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
        .fullScreenCover(item: $viewing) { selection in
            PictureViewer(pictures: pictures, index: selection.index)
        }
    }
}

struct PictureSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

/// One picture at a time, as large as the screen allows; left / right for the others, Menu to close.
struct PictureViewer: View {
    let pictures: [CommentPicture]
    @State var index: Int
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: Self.fullSize(pictures[index].url)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else if phase.error != nil {
                    Label("图片加载失败", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.textSecondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(index)
            if pictures.count > 1 {
                Text("\(index + 1) / \(pictures.count)")
                    .font(Theme.Font.meta.monospacedDigit())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onMoveCommand { direction in
            switch direction {
            case .left: index = max(0, index - 1)
            case .right: index = min(pictures.count - 1, index + 1)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图片")
        .accessibilityIdentifier("comment.pictureViewer")
        .accessibilityValue("\(index + 1)")
    }

    /// Width-limited original (the CDN keeps the aspect ratio when only a width is given).
    static func fullSize(_ url: String) -> URL? {
        let base = BiliText.imageURL(url)
        return URL(string: base.contains("hdslb.com") ? base + "@1920w.webp" : base)
    }
}
