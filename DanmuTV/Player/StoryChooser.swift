import BiliKit
import SwiftUI
import UIKit

/// 互动视频: where the viewer is in a story, carried by the player from module to module.
struct StorySession {
    struct Step {
        var edge: StoryEdge
        var cid: Int
        var state: StoryState
    }

    let aid: Int
    let bvid: String
    let graphVersion: Int
    var edge: StoryEdge
    var cid: Int
    var state = StoryState()
    /// Modules already left, for 返回上一步.
    var history: [Step] = []

    init(aid: Int, bvid: String, graphVersion: Int, start: StoryEdge, cid: Int) {
        self.aid = aid
        self.bvid = bvid
        self.graphVersion = graphVersion
        edge = start
        self.cid = cid
        state.enter(start)
    }
}

/// What the viewer did in the chooser.
enum StoryPick {
    case choice(StoryEdge.Choice)
    case back
    case restart
}

/// The choices at the end of a module, over the paused last frame. Menu closes it (the player stays, and 选择剧情
/// brings it back).
final class StoryChooserController: UIHostingController<StoryChooserView> {
    init(edge: StoryEdge, choices: [StoryEdge.Choice], timeLimit: Double?, defaultChoice: StoryEdge.Choice?,
         canGoBack: Bool, onPick: @escaping (StoryPick) -> Void)
    {
        var picked = false
        var dismiss: (() -> Void)?
        let pick: (StoryPick) -> Void = { p in
            guard !picked else { return }
            picked = true
            dismiss?()
            onPick(p)
        }
        super.init(rootView: StoryChooserView(title: edge.title, isEnding: edge.isLeaf, choices: choices, timeLimit: timeLimit,
                                              defaultChoice: defaultChoice, canGoBack: canGoBack, onPick: pick))
        modalPresentationStyle = .overFullScreen
        view.backgroundColor = .clear
        dismiss = { [weak self] in self?.dismiss(animated: true) }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder _: NSCoder) { fatalError() }
}

struct StoryChooserView: View {
    let title: String
    let isEnding: Bool
    let choices: [StoryEdge.Choice]
    let timeLimit: Double?
    let defaultChoice: StoryEdge.Choice?
    let canGoBack: Bool
    let onPick: (StoryPick) -> Void

    @State private var remaining: Double = 0
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Spacer()
            Text(isEnding ? "剧情结束" : "做出你的选择")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.accent)
            if !title.isEmpty {
                Text(title).font(Theme.Font.title).lineLimit(1)
            }
            if let timeLimit, !isEnding {
                ProgressView(value: max(0, remaining), total: timeLimit)
                    .tint(.white)
                    .frame(maxWidth: 600)
            }
            ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                ForEach(Array(choices.enumerated()), id: \.offset) { i, choice in
                    Button { onPick(.choice(choice)) } label: {
                        Text(choice.text)
                            .font(Theme.Font.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 640)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonBorderShape(.capsule)
                    .focused($focused, equals: i)
                    .accessibilityIdentifier("story.choice.\(i)")
                }
                if isEnding {
                    Button { onPick(.restart) } label: { Label("从头开始", systemImage: "arrow.counterclockwise").font(Theme.Font.headline) }
                        .buttonBorderShape(.capsule)
                        .focused($focused, equals: 100)
                }
                if canGoBack {
                    Button { onPick(.back) } label: { Label("返回上一步", systemImage: "arrow.uturn.backward").font(Theme.Font.headline) }
                        .buttonBorderShape(.capsule)
                        .focused($focused, equals: 101)
                }
            }
            .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, 90)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 560)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onAppear {
            remaining = timeLimit ?? 0
            let index = defaultChoice.flatMap { d in choices.firstIndex(of: d) } ?? 0
            focused = choices.isEmpty ? (isEnding ? 100 : 101) : index
        }
        .task {
            // Out of time: Bilibili's default (or the first allowed) choice is taken, as on the phone.
            guard let timeLimit, !isEnding, let defaultChoice else { return }
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                remaining = timeLimit - Date().timeIntervalSince(start)
                if remaining <= 0 {
                    onPick(.choice(defaultChoice))
                    return
                }
            }
        }
    }
}
