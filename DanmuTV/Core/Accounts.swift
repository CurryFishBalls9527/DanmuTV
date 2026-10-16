import BiliKit
import Foundation
import Observation
import TVServices

/// Up to `maxProfiles` logged-in Bilibili accounts. Each account is its own Keychain item
/// (`account.<mid>`), optionally in iCloud Keychain so profiles sync between Apple TVs.
/// Which profile is active is stored locally, so devices never fight over it.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()
    static let maxProfiles = 5

    private static let itemPrefix = "account."
    private static let currentKey = "accounts.current"
    private static let reLoginKey = "accounts.needsReLogin"

    private(set) var accounts: [Account] = []
    private(set) var currentID: Int?
    /// Profiles whose session the server rejected; kept (not deleted) until the user scans again.
    private(set) var expiredIDs: Set<Int>

    /// Drives the app's single QR-login sheet (add profile, re-login after expiry, deep link).
    var isLoginPresented = false
    /// tvOS 多用户: this Apple TV user opens the app for the first time and there are profiles to choose from
    /// (「谁在看？」). Their choice is remembered for them (settings are per user), so later it's automatic.
    var needsProfileChoice = false
    /// 「登录其他账号」 was picked: login opens once the question's cover has gone (a sheet can't open while it leaves).
    var loginAfterProfileChoice = false
    var currentNeedsReLogin: Bool { currentID.map { expiredIDs.contains($0) } ?? false }
    private var isVerifyingAuth = false

    var current: Account? { accounts.first { $0.mid == currentID } }
    var isLoggedIn: Bool { current != nil }
    var canAddProfile: Bool { accounts.count < Self.maxProfiles }

    private init() {
        // Earlier builds stored accounts under another Keychain service name; adopt them once.
        if !UserDefaults.standard.bool(forKey: "keychain.adopted.danmutv") {
            Keychain.adoptItems(prefix: Self.itemPrefix)
            UserDefaults.standard.set(true, forKey: "keychain.adopted.danmutv")
        }
        if Keychain.userIndependent, !UserDefaults.standard.bool(forKey: "keychain.adopted.userIndependent") {
            // Retried next launch if anything couldn't be copied.
            if Keychain.adoptUserItems(prefix: Self.itemPrefix) { UserDefaults.standard.set(true, forKey: "keychain.adopted.userIndependent") }
        }
        expiredIDs = Set(UserDefaults.standard.array(forKey: Self.reLoginKey) as? [Int] ?? [])
        let chosenBefore = UserDefaults.standard.object(forKey: Self.currentKey) != nil
        reload()
        Log.account.info("profiles: \(self.accounts.count), user-independent keychain: \(Keychain.userIndependent), chosen before: \(chosenBefore)")
        needsProfileChoice = Keychain.userIndependent && TVUserManager().shouldStorePreferencesForCurrentUser
            && !chosenBefore && !accounts.isEmpty
        #if DEBUG
        // UI tests: `-forceProfileChoice YES` shows the question whatever the device.
        if UserDefaults.standard.bool(forKey: "forceProfileChoice") { needsProfileChoice = true }
        #endif
    }

    /// 「谁在看？」 answered (or dismissed: then the profile shown stays, and the question isn't asked again).
    func profileChosen(_ mid: Int?) {
        needsProfileChoice = false
        if let mid { switchTo(mid) } else if let currentID { UserDefaults.standard.set(currentID, forKey: Self.currentKey) }
    }

    /// Re-reads the Keychain (picks up profiles / rotated tokens synced from other devices).
    func reload() {
        let scope: Keychain.Scope = AppSettings.shared.iCloudSync ? .any : .local
        var newest: [Int: (account: Account, modified: Date)] = [:]
        for item in Keychain.items(prefix: Self.itemPrefix, scope: scope) {
            guard let account = try? JSONDecoder().decode(Account.self, from: item.data) else { continue }
            if let existing = newest[account.mid], existing.modified >= item.modified { continue }
            newest[account.mid] = (account, item.modified)
        }
        // Keep the on-screen order stable; new arrivals go to the end.
        let known = accounts.map(\.mid).filter { newest[$0] != nil }
        let added = newest.keys.filter { !known.contains($0) }.sorted()
        accounts = (known + added).compactMap { newest[$0]?.account }

        let saved = UserDefaults.standard.object(forKey: Self.currentKey) as? Int
        let previous = currentID
        currentID = accounts.contains { $0.mid == saved } ? saved : accounts.first?.mid
        BiliClient.shared.setAccount(current)
        if previous != nil, previous != currentID {
            NotificationCenter.default.post(name: .accountChanged, object: nil)
        }
    }

    func add(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.mid == account.mid }) {
            accounts[i] = account
        } else {
            guard canAddProfile else { return }
            accounts.append(account)
        }
        setExpired(account.mid, false)
        persist(account)
        switchTo(account.mid)
    }

    func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.mid == account.mid }) else { return }
        accounts[i] = account
        if account.mid == currentID { BiliClient.shared.setAccount(account) }
        persist(account)
    }

    func switchTo(_ mid: Int) {
        guard accounts.contains(where: { $0.mid == mid }) else { return }
        let changed = currentID != mid
        currentID = mid
        UserDefaults.standard.set(mid, forKey: Self.currentKey)
        BiliClient.shared.setAccount(current)
        if changed { NotificationCenter.default.post(name: .accountChanged, object: nil) }
        if expiredIDs.contains(mid) { isLoginPresented = true }
        Task { await refreshTokenIfNeeded() }
    }

    /// User-initiated removal; with iCloud sync on this removes the profile on every device.
    func remove(_ mid: Int) {
        accounts.removeAll { $0.mid == mid }
        Keychain.delete(Self.itemPrefix + String(mid), scope: AppSettings.shared.iCloudSync ? .any : .local)
        setExpired(mid, false)
        if currentID == mid {
            currentID = accounts.first?.mid
            UserDefaults.standard.set(currentID, forKey: Self.currentKey)
            BiliClient.shared.setAccount(current)
            NotificationCenter.default.post(name: .accountChanged, object: nil)
        }
    }

    /// 清空所有登录信息, including the copies in iCloud Keychain.
    func removeAll() {
        for account in accounts {
            Keychain.delete(Self.itemPrefix + String(account.mid), scope: .any)
        }
        for item in Keychain.items(prefix: Self.itemPrefix, scope: .any) {
            Keychain.delete(item.key, scope: .any)
        }
        accounts = []
        currentID = nil
        expiredIDs = []
        UserDefaults.standard.removeObject(forKey: Self.currentKey)
        UserDefaults.standard.removeObject(forKey: Self.reLoginKey)
        BiliClient.shared.setAccount(nil)
        NotificationCenter.default.post(name: .accountChanged, object: nil)
    }

    private func persist(_ account: Account) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        Keychain.upsert(data, for: Self.itemPrefix + String(account.mid), synced: AppSettings.shared.iCloudSync)
    }

    /// Moves every profile into / out of iCloud Keychain after the sync setting changes.
    /// Turning sync off keeps local copies and leaves the iCloud copies alone, so other devices aren't logged out.
    func syncSettingChanged() {
        let synced = AppSettings.shared.iCloudSync
        for account in accounts {
            persist(account)
            if synced { Keychain.delete(Self.itemPrefix + String(account.mid), scope: .local) }
        }
        reload()
    }

    struct SyncStatus {
        var local: Int
        var synced: Int
    }

    func syncStatus() -> SyncStatus {
        SyncStatus(local: Keychain.items(prefix: Self.itemPrefix, scope: .local).count,
                   synced: Keychain.items(prefix: Self.itemPrefix, scope: .synced).count)
    }

    /// Removes the iCloud Keychain copies only; this device keeps its accounts (saved locally).
    func clearICloudAccounts() {
        for account in accounts {
            if let data = try? JSONEncoder().encode(account) {
                Keychain.upsert(data, for: Self.itemPrefix + String(account.mid), synced: false)
            }
        }
        for item in Keychain.items(prefix: Self.itemPrefix, scope: .synced) {
            Keychain.delete(item.key, scope: .synced)
        }
        if AppSettings.shared.iCloudSync { AppSettings.shared.iCloudSync = false }
    }

    private func setExpired(_ mid: Int, _ expired: Bool) {
        if expired { expiredIDs.insert(mid) } else { expiredIDs.remove(mid) }
        UserDefaults.standard.set(Array(expiredIDs), forKey: Self.reLoginKey)
    }

    /// Refreshes the active account's app token when it is within a week of expiring.
    /// Runs at launch, on returning to the foreground and on profile switch.
    func refreshTokenIfNeeded() async {
        guard let account = current, !expiredIDs.contains(account.mid),
              account.expiresAt.timeIntervalSinceNow < 7 * 86400
        else { return }
        if let updated = try? await API.refresh(account), accounts.contains(where: { $0.mid == updated.mid }) {
            update(updated)
        }
    }

    /// Called when an API returned -101 for a logged-in request. Confirms with /nav and tries a
    /// token refresh before marking the profile as needing re-login (the profile is kept).
    func handleAuthFailure() async {
        guard let account = current, !isVerifyingAuth else { return }
        isVerifyingAuth = true
        defer { isVerifyingAuth = false }
        guard let nav = try? await API.nav(as: account), !nav["isLogin"].bool else { return }
        if let refreshed = try? await API.refresh(account) {
            update(refreshed)
            if let again = try? await API.nav(as: refreshed), again["isLogin"].bool { return }
        }
        setExpired(account.mid, true)
        // The user may have switched profiles while we were verifying.
        if currentID == account.mid { isLoginPresented = true }
    }

    /// Refreshes the face/name of the current account from the server.
    func refreshProfile() async {
        guard let mid = currentID, let snapshot = current,
              let info = try? await API.nav(as: snapshot), info["isLogin"].bool,
              // Re-read: tokens may have been refreshed while we awaited.
              var account = accounts.first(where: { $0.mid == mid })
        else { return }
        account.name = info["uname"].string ?? account.name
        account.face = info["face"].string ?? account.face
        update(account)
    }
}

extension Notification.Name {
    static let accountChanged = Notification.Name("DanmuTV.accountChanged")
}
