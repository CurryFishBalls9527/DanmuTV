import AVFoundation
import BiliKit

/// Serves generated HLS playlists for Bilibili DASH streams to AVPlayer.
///
/// AVPlayer can't play DASH, but it can play HLS whose media playlists address byte ranges of
/// fMP4 files. The master and media playlists are answered here via a custom URL scheme (built by
/// `HLSSession`); the media segments are plain https URLs on the Bilibili CDN, fetched by AVPlayer
/// with the Referer/User-Agent from `AVURLAssetHTTPHeaderFieldsKey`.
final class DashResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "bilihls"
    static let masterURL = URL(string: "\(scheme)://play/master.m3u8")!

    let session: HLSSession
    let queue = DispatchQueue(label: "DanmuTV.hls-loader")
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    var selection: StreamSelection { session.selection }

    init(selection: StreamSelection, policy: CDNPolicy, fastLoad: Bool) {
        session = HLSSession(selection: selection, policy: policy, fastLoad: fastLoad) { url, range in
            try await BiliClient.shared.rangeData(url, range)
        }
    }

    func resourceLoader(_: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, url.scheme == Self.scheme else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        if name == "master" {
            respond(request, with: session.masterPlaylist(scheme: Self.scheme))
            return true
        }
        let key = ObjectIdentifier(request)
        let task = Task { [session] in
            defer { self.lock.withLock { _ = self.tasks.removeValue(forKey: key) } }
            do {
                let playlist = try await session.mediaPlaylist(named: name)
                guard !request.isCancelled else { return }
                self.respond(request, with: playlist)
            } catch {
                guard !request.isCancelled else { return }
                request.finishLoading(with: error)
            }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        let task = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(request)) }
        task?.cancel()
    }

    private func respond(_ request: AVAssetResourceLoadingRequest, with playlist: String) {
        request.dataRequest?.respond(with: Data(playlist.utf8))
        request.finishLoading()
    }
}
