import BiliKit
import CoreGraphics
import Foundation

/// 弹幕防挡: a video's person mask, fetched the first time it's needed, decoded one 10-second segment at a time
/// in the background (only segments around the playhead), each frame pre-drawn into a small alpha bitmap.
/// Main-actor API; nothing heavy runs on the main thread.
@MainActor
final class DanmakuMaskSource {
    struct Frame {
        /// ms.
        var time: Int
        /// Alpha-only, at most 256 px a side: opaque where danmaku may show.
        var image: CGImage
    }

    enum State {
        case idle, loading, ready, failed
    }

    let info: DanmakuMaskInfo
    private(set) var state = State.idle
    /// Called when the mask turns out to be unavailable (the menu drops its toggle).
    var onFailure: (() -> Void)?

    private var mask: WebMask?
    private var downloadTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    /// Decoded segments by index; only the ones around the playhead are kept.
    private var decoded: [Int: [Frame]] = [:]
    /// Segment the playhead is in, so a queued decode that's no longer near it is skipped.
    private var wantedIndex = 0

    init(info: DanmakuMaskInfo) {
        self.info = info
    }

    func cancel() {
        downloadTask?.cancel()
        decodeTask?.cancel()
        decoded = [:]
    }

    /// The frame showing at `seconds`, or nil while its segment isn't ready (danmaku then draw unmasked briefly,
    /// e.g. right after a seek). The first call starts the download.
    func frame(at seconds: Double) -> Frame? {
        switch state {
        case .idle:
            state = .loading
            downloadTask = Task { [weak self] in await self?.download() }
            return nil
        case .loading, .failed:
            return nil
        case .ready:
            break
        }
        guard let mask, seconds.isFinite else { return nil }
        let ms = Int(seconds * 1000)
        guard let index = mask.segmentIndex(at: ms) else { return nil }
        if index != wantedIndex || decodeTask == nil {
            wantedIndex = index
            for key in decoded.keys where key < index - 1 || key > index + 1 { decoded[key] = nil }
            decodeNext()
        }
        guard let frames = decoded[index], let first = frames.first else { return nil }
        guard first.time <= ms else { return first }
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if frames[mid].time <= ms { low = mid } else { high = mid - 1 }
        }
        return frames[low]
    }

    /// Decodes the wanted segment, then the next; one at a time.
    private func decodeNext() {
        guard decodeTask == nil, let mask else { return }
        guard let index = [wantedIndex, wantedIndex + 1].first(where: { $0 < mask.segments.count && decoded[$0] == nil }) else { return }
        decodeTask = Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            let frames = (try? mask.frames(ofSegment: index))?.compactMap { f -> Frame? in
                guard !Task.isCancelled, let image = SVGMask.shape(fromFrame: f.svg)?.alphaImage() else { return nil }
                return Frame(time: f.time, image: image)
            } ?? []
            let elapsed = Date().timeIntervalSince(started)
            await self?.store(index, frames, elapsed: elapsed)
        }
    }

    private func store(_ index: Int, _ frames: [Frame], elapsed: TimeInterval) {
        decodeTask = nil
        // Seeked far away meanwhile: drop it.
        if abs(index - wantedIndex) <= 1 {
            decoded[index] = frames
            Log.player.info("danmaku mask segment \(index): \(frames.count) frames in \(Int(elapsed * 1000)) ms")
        }
        decodeNext()
    }

    private func download() async {
        var request = URLRequest(url: info.url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BiliError.invalidResponse }
            let parsed = try await Task.detached(priority: .utility) { try WebMask(data: data) }.value
            guard !Task.isCancelled else { return }
            mask = parsed
            state = .ready
            Log.player.info("danmaku mask: \(parsed.segments.count) segments, \(data.count / 1024) KB")
        } catch {
            guard !BiliClient.isCancellation(error), !Task.isCancelled else { return }
            state = .failed
            Log.player.error("danmaku mask unavailable: \(error.localizedDescription, privacy: .public)")
            onFailure?()
        }
    }
}
