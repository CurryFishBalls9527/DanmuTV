import Foundation

/// A player's position between items, generic over what an item plays (`Target`). The player reads and writes
/// "what's current" only through `target`, so during a switch every change lands on what is loading, and the
/// attached item's record can't be touched until `rollBack` hands it back. That keeps what is on screen and what is
/// being loaded from drifting apart (progress saved under a page that never loaded, a failed switch going back to
/// state that belongs to the new page).
public enum PlaybackPhase<Target> {
    /// The first item is loading: nothing attached yet.
    case starting(Target)
    /// The attached item plays `Target`; reloading it in place (quality, recovery) stays here.
    case playing(Target)
    /// Leaving `from` (still attached) for `to`, which is loading.
    case switching(from: Target, to: Target)

    /// What is current: the attached item's, or what is loading to replace it.
    public var target: Target {
        get {
            switch self {
            case let .starting(target), let .playing(target), let .switching(from: _, to: target): return target
            }
        }
        set {
            switch self {
            case .starting: self = .starting(newValue)
            case .playing: self = .playing(newValue)
            case let .switching(from, _): self = .switching(from: from, to: newValue)
            }
        }
    }

    /// What the attached item plays; nil before the first item.
    public var attached: Target? {
        switch self {
        case .starting: return nil
        case let .playing(target), let .switching(from: target, to: _): return target
        }
    }

    public var isSwitching: Bool {
        if case .switching = self { return true }
        return false
    }

    /// Starts loading `next` to replace the attached item. Already switching: still away from the same item, now
    /// towards `next`. Before the first item there's nothing to go back to.
    public mutating func beginSwitch(to next: Target) {
        switch self {
        case .starting: self = .starting(next)
        case let .playing(attached), let .switching(from: attached, to: _): self = .switching(from: attached, to: next)
        }
    }

    /// The target's item is attached and playing.
    public mutating func attach() {
        self = .playing(target)
    }

    /// The switch didn't happen: the item it was leaving, playing again; nil when not switching.
    @discardableResult
    public mutating func rollBack() -> Target? {
        guard case let .switching(from, _) = self else { return nil }
        self = .playing(from)
        return from
    }
}
