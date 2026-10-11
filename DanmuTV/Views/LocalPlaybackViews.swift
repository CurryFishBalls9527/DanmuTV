import AMSMB2
import BiliKit
import SwiftUI

// MARK: Model

/// An SMB server (NAS / computer share). The password lives in the Keychain, never in UserDefaults.
struct SMBServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int?
    var user: String

    private var keychainKey: String { "smb.\(id.uuidString)" }

    /// Exact-key read (doesn't scan the other Keychain items).
    var password: String {
        Keychain.data(for: keychainKey, scope: .local).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func savePassword(_ password: String) {
        Keychain.upsert(Data(password.utf8), for: keychainKey, synced: false)
    }

    /// "DOMAIN\\user" → ("DOMAIN", "user").
    var domainAndUser: (domain: String, user: String) {
        let parts = user.split(separator: "\\", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : ("", user)
    }

    /// A manager for these settings with an explicit password (used to test before saving).
    func manager(password: String) -> SMB2Manager? {
        guard let url = SMBAddress.serverURL(host: host, port: port) else { return nil }
        let (domain, name) = domainAndUser
        let credential = name.isEmpty ? nil : URLCredential(user: name, password: password, persistence: .forSession)
        let manager = SMB2Manager(url: url, domain: domain, credential: credential)
        manager?.timeout = 10 // a dead NAS shouldn't spin for a minute
        return manager
    }

    func mediaURL(share: String, path: String) -> URL? {
        SMBAddress.mediaURL(host: host, port: port, share: share, path: path)
    }
}

@MainActor
@Observable
final class SMBStore {
    static let shared = SMBStore()
    private(set) var servers: [SMBServer] = []
    private let key = "smb.servers"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([SMBServer].self, from: data) {
            servers = list
        }
    }

    /// One connection per server, reused across folders (each new one is a full NTLM handshake).
    private var managers: [UUID: SMB2Manager] = [:]

    func manager(for server: SMBServer) -> SMB2Manager? {
        if let cached = managers[server.id] { return cached }
        let manager = server.manager(password: server.password)
        managers[server.id] = manager
        return manager
    }

    /// Saves after a successful connection test; only then is the password written.
    func save(_ server: SMBServer, password: String) {
        server.savePassword(password)
        managers[server.id] = nil
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server } else { servers.append(server) }
        persist()
    }

    func remove(_ server: SMBServer) {
        servers.removeAll { $0.id == server.id }
        managers[server.id] = nil
        Keychain.delete("smb.\(server.id.uuidString)", scope: .local)
        // Its saved playback positions go too.
        let prefix = "local.resume.\(server.id.uuidString)"
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: key)
    }
}

struct SMBEntry: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var id: String { path }
}

struct SMBLocation: Hashable {
    var server: SMBServer
    var share: String?
    var path: String
}

// MARK: Views

/// 本地播放: SMB servers.
struct LocalSourcesView: View {
    @State private var store = SMBStore.shared
    @State private var editing: SMBServer?
    @State private var adding = false
    @State private var deleting: SMBServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                PageTitle(title: "本地播放", subtitle: "局域网共享（SMB）里的视频，支持 MKV / AVI / FLV 等格式")
                if store.servers.isEmpty {
                    StatePlaceholder(systemImage: "externaldrive.connected.to.line.below", title: "还没有添加共享",
                                     message: "添加 NAS 或电脑的 SMB 共享，即可直接播放其中的视频")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gridSpacing), count: 4), spacing: Theme.Spacing.l) {
                    ForEach(store.servers) { server in
                        NavigationLink(value: SMBLocation(server: server, share: nil, path: "")) {
                            VStack(spacing: Theme.Spacing.s) {
                                Image(systemName: "externaldrive.fill.badge.wifi").font(.system(size: 54, weight: .light))
                                Text(server.name).font(Theme.Font.card).lineLimit(1)
                                Text(server.host).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .background(Theme.surface)
                        }
                        .buttonStyle(.card)
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { editing = server }
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = server }
                        }
                    }
                    Button {
                        adding = true
                    } label: {
                        VStack(spacing: Theme.Spacing.s) {
                            Image(systemName: "plus").font(.system(size: 54, weight: .light))
                            Text("添加共享").font(Theme.Font.card)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .background(Theme.surface)
                    }
                    .buttonStyle(.card)
                }
                .padding(.horizontal, Theme.pagePadding)
                .focusSection()
                if !store.servers.isEmpty {
                    Text("长按一个共享可以编辑或删除").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.top, Theme.Spacing.s)
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .ambient("")
        .sheet(isPresented: $adding) { SMBServerEditor(server: nil) }
        .sheet(item: $editing) { SMBServerEditor(server: $0) }
        .confirmationDialog("删除共享？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting)
        { server in
            Button("删除「\(server.name)」", role: .destructive) { store.remove(server) }
        } message: { _ in
            Text("会同时清除这个共享里的播放进度。")
        }
    }
}

struct SMBServerEditor: View {
    let server: SMBServer?
    @Environment(\.dismiss) private var dismiss
    /// Stable for the whole editing session, so failed attempts don't leave stray Keychain items.
    @State private var draftID = UUID()
    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var testing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（如：书房 NAS）", text: $name)
                    TextField("地址（如 192.168.1.10 或 nas.local）", text: $host)
                    TextField("用户名（访客可留空）", text: $user)
                    SecureField("密码", text: $password)
                }
                Section {
                    Button(testing ? "正在连接…" : "保存") { Task { await save() } }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(server == nil ? "添加共享" : "编辑共享")
        }
        .onAppear {
            if let server {
                name = server.name
                host = server.port.map { "\(server.host):\($0)" } ?? server.host
                user = server.user
                password = server.password
            }
        }
    }

    /// Tests the typed credentials first; the stored password is only replaced after success.
    private func save() async {
        guard let address = SMBAddress.parse(host) else {
            message = "地址格式不对：只填服务器地址，例如 192.168.1.10、nas.local 或 nas.local:445"
            return
        }
        testing = true
        defer { testing = false }
        var s = server ?? SMBServer(id: draftID, name: "", host: "", user: "")
        s.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? address.host : name
        s.host = address.host
        s.port = address.port
        s.user = user.trimmingCharacters(in: .whitespaces)
        guard let manager = s.manager(password: password) else {
            message = "地址无效"
            return
        }
        do {
            _ = try await manager.listShares()
            SMBStore.shared.save(s, password: password)
            dismiss()
        } catch {
            message = "无法连接：\(error.localizedDescription)"
        }
    }
}

/// Shares of a server, or one folder of a share.
struct SMBFolderView: View {
    let location: SMBLocation

    @State private var entries: [SMBEntry] = []
    @State private var phase: Phase = .loading
    private enum Phase: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
            case let .failed(message):
                ErrorRetryView(message: message) { Task { await load() } }
            case .loaded:
                if entries.isEmpty {
                    EmptyStateView(message: "这个文件夹里没有视频", systemImage: "folder")
                } else {
                    List(entries) { entry in
                        if entry.isDirectory {
                            NavigationLink(value: SMBLocation(server: location.server, share: location.share ?? entry.name,
                                                              path: location.share == nil ? "" : entry.path)) {
                                Label(entry.name, systemImage: location.share == nil ? "externaldrive" : "folder")
                            }
                        } else {
                            Button {
                                play(entry)
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: "film")
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(location.share == nil ? location.server.name : ((location.path as NSString).lastPathComponent.isEmpty ? location.share! : (location.path as NSString).lastPathComponent))
        .task { if phase == .loading { await load() } }
    }

    private func load() async {
        phase = .loading
        guard let manager = SMBStore.shared.manager(for: location.server) else {
            phase = .failed("地址无效")
            return
        }
        do {
            if let share = location.share {
                try await manager.connectShare(name: share)
                let items = try await manager.contentsOfDirectory(atPath: location.path)
                let raw = items.map { item -> LocalEntry in
                    let name = item[.nameKey] as? String ?? ""
                    return LocalEntry(name: name,
                                      path: item[.pathKey] as? String ?? (location.path as NSString).appendingPathComponent(name),
                                      isDirectory: (item[.isDirectoryKey] as? Bool) ?? false,
                                      size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
                }
                // Hidden/system folders out, folders first, natural order (第2集 before 第10集).
                entries = LocalListing.visible(raw).map { SMBEntry(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size) }
                allFiles = raw.map(\.name)
            } else {
                entries = try await manager.listShares().map {
                    SMBEntry(name: $0.name, path: $0.name, isDirectory: true, size: 0)
                }
            }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @State private var allFiles: [String] = []

    private func play(_ entry: SMBEntry) {
        guard let share = location.share else { return }
        let folder = (entry.path as NSString).deletingLastPathComponent
        // 本地视频也可以加载弹幕文件 (<name>.xml / .danmaku.xml / .cmt.xml) and subtitle sidecars.
        let danmaku = Sidecar.danmaku(for: entry.name, in: allFiles).map { (folder as NSString).appendingPathComponent($0) }
        let subtitles = Sidecar.subtitles(for: entry.name, in: allFiles).map { (folder as NSString).appendingPathComponent($0) }
        PlayerLauncher.present(LocalFilePlayerViewController(server: location.server, share: share, path: entry.path,
                                                             title: entry.name, danmakuPath: danmaku, subtitlePaths: subtitles))
    }
}
