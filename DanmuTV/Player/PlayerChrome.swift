import UIKit

/// Shared chrome for player overlays: dark translucent material pills and panels that match the
/// system transport bar, so toasts, status and HUDs read as part of the player rather than stickers on it.
@MainActor
enum PlayerChrome {
    static let accent = UIColor(red: 0.984, green: 0.447, blue: 0.6, alpha: 1)
    /// Distance from the screen edge for anything pinned to a corner.
    static let edgeInset: CGFloat = 60

    static func material(cornerRadius: CGFloat) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        view.isUserInteractionEnabled = false
        return view
    }
}

/// One-line notice pinned to a corner (已跳过片头 / 人气 1.2万 / 弹幕已断开). Fades out after `autoHide`.
@MainActor
final class HUDPill: UIView {
    enum Corner { case topLeading, topTrailing }

    private let blur = PlayerChrome.material(cornerRadius: 22)
    private let label = UILabel()
    private var hideTask: Task<Void, Never>?
    private let padding = UIEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.font = .systemFont(ofSize: 27, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(blur)
        blur.contentView.addSubview(label)
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Shows `text` in `corner` of `container` (the superview's bounds). `autoHide` nil keeps it up.
    func show(_ text: String, in container: CGRect, corner: Corner = .topTrailing, autoHide: TimeInterval? = 2.5) {
        label.text = text
        let textSize = label.sizeThatFits(CGSize(width: container.width * 0.6, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(textSize.width) + padding.left + padding.right, height: ceil(textSize.height) + padding.top + padding.bottom)
        let x = corner == .topLeading ? PlayerChrome.edgeInset : container.width - size.width - PlayerChrome.edgeInset
        frame = CGRect(x: x, y: PlayerChrome.edgeInset, width: size.width, height: size.height)
        blur.frame = bounds
        label.frame = bounds.inset(by: padding)
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        hideTask?.cancel()
        guard let autoHide else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoHide * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        UIView.animate(withDuration: 0.4) { self.alpha = 0 }
    }
}

/// Multi-line panel: a title, a secondary line (or lines) and an optional progress bar. Used as the
/// status overlay of the VLC live player and the transport HUD of the local-file player.
@MainActor
final class HUDPanel: UIView {
    enum Placement {
        /// Natural size, pinned top-left.
        case topLeading
        /// Full width minus margins, pinned to the bottom.
        case bottom
    }

    private let blur = PlayerChrome.material(cornerRadius: 26)
    let titleLabel = UILabel()
    let bodyLabel = UILabel()
    let progress = UIProgressView(progressViewStyle: .default)
    var showsProgress = false { didSet { progress.isHidden = !showsProgress } }
    private var hideTask: Task<Void, Never>?
    private let padding = UIEdgeInsets(top: 22, left: 30, bottom: 22, right: 30)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .white
        bodyLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .regular)
        bodyLabel.textColor = UIColor(white: 1, alpha: 0.8)
        bodyLabel.numberOfLines = 0
        progress.progressTintColor = PlayerChrome.accent
        progress.trackTintColor = UIColor(white: 1, alpha: 0.2)
        progress.isHidden = true
        addSubview(blur)
        [titleLabel, bodyLabel, progress].forEach(blur.contentView.addSubview)
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Lays the panel out for its current text inside `container` (the superview's bounds).
    func layout(in container: CGRect, placement: Placement) {
        let maxTextWidth = placement == .bottom ? container.width - 160 - padding.left - padding.right : container.width * 0.6
        let titleSize = titleLabel.sizeThatFits(CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
        let bodySize = bodyLabel.sizeThatFits(CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
        let textWidth = placement == .bottom ? maxTextWidth : max(titleSize.width, bodySize.width)
        var height = padding.top + ceil(titleSize.height) + 8 + ceil(bodySize.height) + padding.bottom
        if showsProgress { height += 26 }
        let width = textWidth + padding.left + padding.right
        switch placement {
        case .topLeading:
            frame = CGRect(x: PlayerChrome.edgeInset, y: PlayerChrome.edgeInset, width: width, height: height)
        case .bottom:
            frame = CGRect(x: 80, y: container.height - height - 70, width: width, height: height)
        }
        blur.frame = bounds
        titleLabel.frame = CGRect(x: padding.left, y: padding.top, width: textWidth, height: ceil(titleSize.height))
        bodyLabel.frame = CGRect(x: padding.left, y: titleLabel.frame.maxY + 8, width: textWidth, height: ceil(bodySize.height))
        progress.frame = CGRect(x: padding.left, y: bodyLabel.frame.maxY + 18, width: textWidth, height: 6)
    }

    /// Fades in; fades out after `autoHide` unless `nil`.
    func show(autoHide: TimeInterval?) {
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        hideTask?.cancel()
        guard let autoHide else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoHide * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        UIView.animate(withDuration: 0.5) { self.alpha = 0 }
    }

    func cancelAutoHide() {
        hideTask?.cancel()
    }
}
