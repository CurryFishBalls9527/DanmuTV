import os

/// Local logging only (no third-party analytics). View with Console.app or
/// `log stream --predicate 'subsystem == "DanmuTV"'`; the player's debug panel reads the same events.
public enum Log {
    public static let network = Logger(subsystem: "DanmuTV", category: "network")
    public static let player = Logger(subsystem: "DanmuTV", category: "player")
    public static let account = Logger(subsystem: "DanmuTV", category: "account")
    public static let cast = Logger(subsystem: "DanmuTV", category: "cast")
}
