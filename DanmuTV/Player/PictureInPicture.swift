import AVKit
import BiliKit
import UIKit

/// 画中画: keeps the player that went into picture in picture alive after AVKit dismisses it, brings it back full
/// screen when asked, and releases it once the window is closed. One at a time: opening another player ends it.
@MainActor
enum PictureInPicture {
    /// The player currently in (or just restored from) picture in picture.
    private(set) static var player: (AVPlayerViewController & PlayerTeardown)?
    private(set) static var isActive = false
    /// Between 全屏 and the player being on screen again (its own dismissal of other modals can take a moment).
    private static var restoring = false

    /// Playback over the rest of the app (and other apps) needs the playback audio session category.
    static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Not activated here: AVPlayer activates it when playback starts, so launching never stops other audio.
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {
            Log.player.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether `controller` is in picture in picture (so leaving the screen or the app must not stop it).
    static func keeps(_ controller: AVPlayerViewController) -> Bool {
        isActive && player === controller
    }

    static func willStart(_ controller: AVPlayerViewController & PlayerTeardown) {
        if let old = player, old !== controller { old.teardown() }
        player = controller
        isActive = true
        Log.player.info("picture in picture: start")
    }

    /// AVKit asks for the full-screen player back (the PiP window's 全屏 button).
    static func restore(_ controller: AVPlayerViewController, completion: @escaping (Bool) -> Void) {
        guard controller.presentingViewController == nil else { return completion(true) }
        restoring = true
        PlayerLauncher.present(controller, animated: false) {
            restoring = false
            completion(true)
        }
    }

    static func didStop(_ controller: AVPlayerViewController & PlayerTeardown) {
        guard player === controller else { return }
        isActive = false
        player = nil
        // Closed rather than restored: nothing shows it any more.
        if controller.presentingViewController == nil, !restoring {
            Log.player.info("picture in picture: closed")
            controller.teardown()
        } else {
            Log.player.info("picture in picture: back to full screen")
        }
    }

    /// Another player is opening: the one in the corner goes away.
    static func end(except controller: UIViewController) {
        guard let current = player, current !== controller else { return }
        isActive = false
        player = nil
        current.teardown()
    }
}
