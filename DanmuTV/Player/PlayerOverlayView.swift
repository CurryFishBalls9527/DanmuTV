import BiliKit
import UIKit

/// Loads a video page's danmaku segment by segment as playback moves: filtering and
/// merging run off the main thread; failed segments are retried; XML is used only if segment 1 can't load.
@MainActor
final class VODDanmakuSource {
    private(set) var timeline = DanmakuTimeline()
    private var cid = 0
    private var filter = DanmakuFilter()
    private var merge = true
    private var useXML = false
    private var inflight: Set<Int> = []
    private var retryAfter: [Int: Date] = [:]
    private var failures: [Int: Int] = [:]
    private var tasks: [Task<Void, Never>] = []
    /// 高能进度条: comment counts over the whole video, from every segment as it loads (before filtering).
    private var heat: HeatCounter?
    private var heatTask: Task<Void, Never>?
    /// Called whenever the heat curve gains a segment: the curve so far, and whether every segment is in.
    var onHeatChange: ((HeatCurve?, Bool) -> Void)?

    private static let maxAttempts = 3
    /// Longest video whose every segment is fetched for the heat curve (20 segments = 2 hours).
    private static let maxHeatSegments = 20

    func reset(cid: Int, filter: DanmakuFilter, merge: Bool) {
        tasks.forEach { $0.cancel() }
        tasks = []
        heatTask?.cancel()
        heatTask = nil
        heat = nil
        self.cid = cid
        self.filter = filter
        self.merge = merge
        timeline = DanmakuTimeline()
        useXML = false
        inflight = []
        retryAfter = [:]
        failures = [:]
    }

    func updateFilter(_ filter: DanmakuFilter) {
        self.filter = filter
        timeline.filter(filter.allows)
    }

    /// Fetches the segment covering `time`, prefetching the next one near its end.
    func ensureLoaded(around time: Double) {
        guard cid > 0, !useXML else { return }
        var wanted = [DanmakuTimeline.segment(for: time)]
        if time.truncatingRemainder(dividingBy: DanmakuTimeline.segmentLength) > DanmakuTimeline.segmentLength - 60 {
            wanted.append(wanted[0] + 1)
        }
        for segment in wanted where !timeline.loadedSegments.contains(segment) && !inflight.contains(segment) {
            if let until = retryAfter[segment], until > Date() { continue }
            fetch(segment)
        }
    }

    /// 高能进度条: counts every comment of the video. Segments the player hasn't reached yet are fetched one at a
    /// time in the background (spaced out, so a long video doesn't burst requests).
    func startHeat(duration: Double) {
        guard cid > 0, duration > 0, heat == nil else { return }
        let counter = HeatCounter(duration: duration)
        guard counter.segmentCount <= Self.maxHeatSegments else { return }
        heat = counter
        let cid = cid
        heatTask = Task { [weak self] in
            for segment in 1 ... counter.segmentCount {
                // Wait out a fetch the playback side already started for this segment.
                while !Task.isCancelled, let self, self.cid == cid, self.inflight.contains(segment) {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                guard let self, self.cid == cid, !Task.isCancelled, !self.useXML else { return }
                guard !self.timeline.loadedSegments.contains(segment) else { continue }
                // Failed on the playback side: its own backoff (and giving up) applies.
                if let until = self.retryAfter[segment], until > Date() { continue }
                self.fetch(segment)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func countHeat(segment: Int, times: [Double]) {
        guard heat?.add(segment: segment, times: times) == true else { return }
        onHeatChange?(heat?.curve, heat?.isComplete ?? false)
    }

    private func fetch(_ segment: Int) {
        inflight.insert(segment)
        let (cid, filter, merge) = (cid, filter, merge)
        tasks.append(Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<(items: [Danmaku], times: [Double]), Error> in
                do {
                    let all = try await API.danmakuSegment(cid: cid, segment: segment)
                    let items = all.filter(filter.allows)
                    return .success((merge ? DanmakuMerger.merge(items) : items, all.map(\.time)))
                } catch {
                    return .failure(error)
                }
            }.value
            self?.finish(segment, cid: cid, result: result)
        })
    }

    private func finish(_ segment: Int, cid: Int, result: Result<(items: [Danmaku], times: [Double]), Error>) {
        guard cid == self.cid else { return }
        inflight.remove(segment)
        switch result {
        case let .success((items, times)):
            timeline.add(items, segment: segment, mergeWindow: merge ? 15 : nil)
            countHeat(segment: segment, times: times)
        case let .failure(error):
            guard !BiliClient.isCancellation(error) else { return }
            let attempts = (failures[segment] ?? 0) + 1
            failures[segment] = attempts
            Log.player.error("danmaku segment \(segment) failed (\(attempts)): \(error.localizedDescription, privacy: .public)")
            if attempts >= Self.maxAttempts, segment == 1, timeline.loadedSegments.isEmpty {
                loadXML()
            } else {
                // Back off; a segment that keeps failing simply stays empty (and counts as empty for the heat curve,
                // so the 高能时刻 markers still come).
                retryAfter[segment] = attempts >= Self.maxAttempts ? .distantFuture : Date().addingTimeInterval(Double(attempts * attempts) * 2)
                if attempts >= Self.maxAttempts { countHeat(segment: segment, times: []) }
            }
        }
    }

    private func loadXML() {
        useXML = true
        let (cid, filter, merge) = (cid, filter, merge)
        tasks.append(Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> (items: [Danmaku], times: [Double])? in
                guard let all = try? await API.danmakuXML(cid: cid) else { return nil }
                let kept = all.filter(filter.allows)
                return (merge ? DanmakuMerger.merge(kept) : kept, all.map(\.time))
            }.value
            guard let self, cid == self.cid else { return }
            if let (items, times) = loaded {
                self.timeline.add(items, segment: 1)
                // The XML list is the whole video (capped by Bilibili): it replaces whatever segments were counted,
                // as every segment at once.
                if let counter = self.heat {
                    self.heat = HeatCounter(duration: counter.duration)
                    for s in 1 ... counter.segmentCount { self.countHeat(segment: s, times: s == 1 ? times : []) }
                }
            } else {
                // Both failed: go back to segments, retrying later.
                self.useXML = false
                self.failures = [:]
                self.retryAfter[1] = Date().addingTimeInterval(30)
            }
        })
    }
}

/// Danmaku + subtitles above the video (inside AVPlayerViewController's contentOverlayView, so they
/// sit under the transport controls and are unaffected by video mirroring). Driven by the player's
/// media time every display refresh: pause, seek, speed and buffering are followed exactly.
@MainActor
final class PlayerOverlayView: UIView {
    /// Current media time and rate, or nil when nothing is playing.
    var timeSource: () -> (time: Double, rate: Double)? = { nil }

    var danmakuEnabled = true {
        didSet {
            renderer.isHidden = !danmakuEnabled
            if !danmakuEnabled { renderer.clear() }
            clock.reset()
        }
    }

    var danmakuArea: Double {
        get { renderer.style.area }
        set { renderer.style.area = newValue }
    }

    private let renderer = DanmakuRenderer()
    /// 弹幕防挡 for the current page, when the video has a mask and it's switched on.
    private var maskSource: DanmakuMaskSource?
    var maskEnabled = true
    /// Where the picture is drawn, in this view's coordinates (letterboxing excluded).
    var videoRect: () -> CGRect = { .zero }
    var videoMirrored = false
    var hasMask: Bool { maskSource.map { $0.state != .failed } ?? false }
    /// The mask turned out unavailable (the player rebuilds its menu).
    var onMaskFailure: (() -> Void)?
    /// Time (ms) of the mask frame applied last, -1 when none (tests read it).
    private(set) var appliedMaskTime = -1
    private let source = VODDanmakuSource()
    private var clock = DanmakuClock()
    private let subtitleLabel = UILabel()
    private let toast = HUDPill()
    private let boostPill = HUDPill()
    private let debugLabel = PaddedLabel()
    private var subtitleLines: [API.SubtitleLine] = []
    private var currentSubtitle: API.SubtitleLine?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// Media time up to which comments have been handed to the rasterizer.
    private var preparedUntil = -Double.infinity
    private static let prepareAhead = 3.0
    private var filter = DanmakuFilter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(renderer)
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.isHidden = true
        addSubview(subtitleLabel)
        addSubview(toast)
        addSubview(boostPill)
        debugLabel.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        debugLabel.textColor = .white
        debugLabel.numberOfLines = 0
        debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        debugLabel.layer.cornerRadius = 12
        debugLabel.layer.cornerCurve = .continuous
        debugLabel.clipsToBounds = true
        debugLabel.isHidden = true
        addSubview(debugLabel)
    }

    /// 调试信息 panel (top-left); nil hides it.
    func setDebugText(_ text: String?) {
        debugLabel.isHidden = text == nil
        guard let text else { return }
        debugLabel.text = text
        let size = debugLabel.sizeThatFits(CGSize(width: bounds.width * 0.6, height: .greatestFiniteMagnitude))
        debugLabel.frame = CGRect(x: 60, y: 60, width: min(size.width + 48, bounds.width * 0.6 + 48), height: size.height + 24)
    }

    /// 长按倍速 indicator (top-left, while the button is held); nil hides it.
    func setBoost(_ text: String?) {
        if let text { boostPill.show(text, in: bounds, corner: .topLeading, autoHide: nil) } else { boostPill.hide() }
    }

    /// Brief top-right notice (e.g. 已跳过片头).
    func showToast(_ text: String) {
        toast.show(text, in: bounds, corner: .topTrailing)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.frame = bounds
        layoutSubtitle()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: Page lifecycle

    /// Starts a new page: clears everything from the previous one (番剧切集时清空上一集的弹幕).
    /// Danmaku filter from Settings (shared by video and live danmaku).
    static func danmakuFilter(accountRules: [JSON]) -> DanmakuFilter {
        let settings = AppSettings.shared
        var f = DanmakuFilter()
        f.minWeight = settings.danmakuMinWeight
        f.showScroll = settings.danmakuShowScroll
        f.showTop = settings.danmakuShowTop
        f.showBottom = settings.danmakuShowBottom
        f.showColored = settings.danmakuShowColored
        f.density = settings.danmakuDensity
        f.blockedWords = settings.danmakuBlockWords
        if settings.danmakuSyncAccountFilter { f.addAccountRules(accountRules) }
        return f
    }

    func load(cid: Int, accountRules: [JSON]) {
        let settings = AppSettings.shared
        let f = Self.danmakuFilter(accountRules: accountRules)
        filter = f
        source.reset(cid: cid, filter: f, merge: settings.danmakuMerge)
        renderer.style = .init(fontSize: settings.danmakuFontSize, scrollDuration: settings.danmakuDuration,
                               opacity: Float(settings.danmakuOpacity), area: renderer.style.area)
        renderer.clear()
        clock.reset()
        preparedUntil = -.infinity
        setSubtitles([])
        setMask(nil)
    }

    /// 高能进度条 for the current page (see `VODDanmakuSource.startHeat`).
    func startHeat(duration: Double, onChange: @escaping (HeatCurve?, Bool) -> Void) {
        source.onHeatChange = onChange
        source.startHeat(duration: duration)
    }

    func setMask(_ info: DanmakuMaskInfo?) {
        maskSource?.cancel()
        maskSource = info.map { DanmakuMaskSource(info: $0) }
        maskSource?.onFailure = { [weak self] in self?.onMaskFailure?() }
        renderer.setMask(nil, videoRect: .zero, mirrored: false)
        appliedMaskTime = -1
    }

    /// Applies (possibly changed) account block rules to the loaded comments.
    func applyAccountRules(_ rules: [JSON]) {
        guard AppSettings.shared.danmakuSyncAccountFilter else { return }
        filter.addAccountRules(rules)
        source.updateFilter(filter)
    }

    func setSubtitles(_ lines: [API.SubtitleLine]) {
        let blocked = AppSettings.shared.subtitleBlockWords.filter { !$0.isEmpty }
        subtitleLines = lines.filter { line in !blocked.contains { line.text.contains($0) } }.sorted { $0.from < $1.from }
        currentSubtitle = nil
        subtitleLabel.isHidden = true
        renderer.bottomInset = 0
    }

    // MARK: Frame loop

    fileprivate func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        guard let sample = timeSource(), sample.time.isFinite else { return }
        let (now, rate) = (sample.time, sample.rate)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if danmakuEnabled {
            source.ensureLoaded(around: now)
            prepareUpcoming(now)
            switch clock.advance(to: now, rate: rate, elapsed: elapsed) {
            case .idle:
                break
            case let .window(from, to):
                renderer.show(source.timeline.due(from: from, to: to), at: now)
            case let .seek(from, to):
                renderer.clear()
                renderer.show(source.timeline.due(from: from, to: to), at: now)
            }
            renderer.step(now: now)
            // Fetched and decoded only while enabled; the video rect is only read when there's a frame to place.
            if let maskFrame = maskEnabled ? maskSource?.frame(at: now) : nil,
               renderer.setMask(maskFrame, videoRect: videoRect(), mirrored: videoMirrored)
            {
                appliedMaskTime = maskFrame.time
            } else {
                renderer.setMask(nil, videoRect: .zero, mirrored: false)
                appliedMaskTime = -1
            }
        }
        if !danmakuEnabled { appliedMaskTime = -1 }
        updateSubtitle(now)
        CATransaction.commit()
    }

    /// Keeps the next few seconds of comments rendering in the background (after a seek, from the new spot).
    private func prepareUpcoming(_ now: Double) {
        if now < preparedUntil - Self.prepareAhead * 2 || now > preparedUntil { preparedUntil = now }
        guard now + Self.prepareAhead / 2 > preparedUntil else { return }
        let until = now + Self.prepareAhead
        renderer.prepare(source.timeline.due(from: preparedUntil, to: until))
        preparedUntil = until
    }

    // MARK: Subtitles

    private func updateSubtitle(_ now: Double) {
        guard !subtitleLines.isEmpty else { return }
        let line = SubtitleLookup.line(at: now, in: subtitleLines)
        guard line != currentSubtitle else { return }
        currentSubtitle = line
        if let line {
            subtitleLabel.attributedText = NSAttributedString(string: line.text, attributes: [
                .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3,
            ])
        }
        subtitleLabel.isHidden = line == nil
        layoutSubtitle()
    }

    private func layoutSubtitle() {
        let size = subtitleLabel.sizeThatFits(CGSize(width: bounds.width * 0.8, height: .greatestFiniteMagnitude))
        subtitleLabel.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 80,
                                     width: size.width, height: size.height)
        // Bottom danmaku stay clear of the subtitle while one is showing.
        renderer.bottomInset = subtitleLabel.isHidden ? 0 : size.height + 100
    }
}

/// CADisplayLink retains its target; the proxy keeps the overlay from leaking.
private final class DisplayLinkProxy: NSObject {
    weak var view: PlayerOverlayView?

    init(_ view: PlayerOverlayView) {
        self.view = view
    }

    @MainActor @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 24, dy: 12))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 48, height: size.height + 24)
    }
}
