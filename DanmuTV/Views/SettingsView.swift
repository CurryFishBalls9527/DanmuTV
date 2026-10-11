import BiliKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var accounts
    @State private var confirmClear = false
    @State private var pendingRemoval: Account?

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let refreshIntervals = [5, 15, 30, 60]
    private static let qualityCaps: [(id: Int, name: String)] = [
        (0, "不限制"), (127, "8K"), (120, "4K"), (116, "1080P60"), (112, "1080P+"), (80, "1080P"), (64, "720P"),
    ]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("外观") {
                NavigationLink("App 图标") { AppIconPicker() }
            }

            Section("通用") {
                Toggle("热门使用匿名模式", isOn: $settings.popularAnonymous)
                Toggle("隐藏「动态」标签页", isOn: $settings.hideDynamicTab)
                Picker("后台自动刷新间隔", selection: $settings.autoRefreshMinutes) {
                    ForEach(Self.refreshIntervals, id: \.self) { Text("\($0) 分钟").tag($0) }
                }
            }

            Section("播放") {
                Picker("默认倍速", selection: $settings.defaultSpeed) {
                    ForEach(Self.speeds, id: \.self) { Text(String(format: "%gx", $0)).tag($0) }
                }
                Toggle("继续播放（从上次进度开始）", isOn: $settings.resumePlayback)
                Toggle("自动连播下一P", isOn: $settings.autoPlayNext)
                Toggle("播完自动播放相关推荐", isOn: $settings.autoPlayRelated)
                Toggle("番剧自动跳过片头片尾", isOn: $settings.autoSkipOPED)
            }

            Section {
                Toggle("允许手机投屏", isOn: $settings.castEnabled)
                    .onChange(of: settings.castEnabled) { CastReceiver.shared.settingChanged() }
            } header: {
                Text("投屏")
            } footer: {
                Text("在哔哩哔哩手机 App 的播放页点「投屏」，选择「\(CastReceiver.shared.deviceName)」。Danmu TV 需要开着（在前台），手机和 Apple TV 需在同一网络。")
            }

            Section {
                Picker("匹配动态范围和帧率", selection: $settings.displayMatchMode) {
                    ForEach(DisplayMatchMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("强制 SDR（不播放 HDR）", isOn: $settings.forceSDR)
                Picker("输出帧率", selection: $settings.forcedRefreshRate) {
                    Text("跟随视频").tag(0.0)
                    ForEach([23.976, 24, 25, 29.97, 30, 50, 59.94, 60], id: \.self) { Text(verbatim: String(format: "%g Hz", $0)).tag($0) }
                }
                .disabled(settings.displayMatchMode == .off)
            } header: {
                Text("显示")
            } footer: {
                Text("需同时在 Apple TV「设置 › 视频与音频 › 匹配内容」中开启。切换 HDMI 信号时黑屏的电视，可选择「仅 HDR / 杜比视界时匹配」或强制 SDR / 59.94 Hz。")
            }

            Section {
                Toggle("HDR10 / HLG", isOn: $settings.enableHDR).disabled(settings.forceSDR)
                Toggle("杜比视界", isOn: $settings.enableDolbyVision).disabled(settings.forceSDR)
                Toggle("杜比全景声 / 杜比音效", isOn: $settings.enableDolbyAudio)
                Toggle("无损音频（FLAC）", isOn: $settings.enableLosslessAudio)
            } header: {
                Text("HDR 与音频")
            } footer: {
                Text("需要大会员及支持的电视/音响。HDR 播放失败时会自动降级为 SDR。")
            }

            Section {
                Picker("优先编码", selection: $settings.codecPreference) {
                    ForEach(CodecPreference.allCases) { Text($0.title).tag($0) }
                }
                Picker("最高画质", selection: $settings.maxQuality) {
                    ForEach(Self.qualityCaps, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("仅加载最高分辨率", isOn: $settings.onlyHighestQuality)
                Toggle("过滤 60 帧以上的视频", isOn: $settings.filterHighFramerate)

            } header: {
                Text("画质")
            } footer: {
                Text("默认按网络带宽自动切换清晰度。不支持所选编码的视频会自动回退到 AVC。出现丢帧或音画不同步时可开启「过滤 60 帧以上的视频」；频繁卡顿可尝试切换 CDN 策略。")
            }

            Section {
                Picker("线路优先级", selection: $settings.cdnStrategy) {
                    ForEach(CDNStrategy.allCases) { Text($0.title).tag($0) }
                }
                Picker("海外优先 Akamai", selection: Binding(get: { settings.cdnPreferAkamai.map { $0 ? 1 : 0 } ?? -1 },
                                                         set: { settings.cdnPreferAkamai = $0 < 0 ? nil : $0 == 1 }))
                {
                    Text("自动（\(AppSettings.isOverseas ? "当前为海外" : "当前为国内")）").tag(-1)
                    Text("开").tag(1)
                    Text("关").tag(0)
                }
                Picker("强制替换线路", selection: $settings.cdnRewriteHost) {
                    Text("不替换").tag("")
                    ForEach(CDNPolicy.presetHosts, id: \.host) { Text($0.name).tag($0.host) }
                    if !settings.cdnRewriteHost.isEmpty, !CDNPolicy.presetHosts.contains(where: { $0.host == settings.cdnRewriteHost }) {
                        Text(settings.cdnRewriteHost).tag(settings.cdnRewriteHost)
                    }
                }
                NavigationLink("自定义线路") {
                    CustomHostEditor(host: $settings.cdnRewriteHost)
                }
                NavigationLink("线路黑名单（\(settings.cdnBlacklist.count)）") {
                    WordListEditor(title: "线路黑名单", words: $settings.cdnBlacklist)
                }
                Toggle("快速加载模式", isOn: $settings.fastLoad)
            } header: {
                Text("CDN 线路")
            } footer: {
                Text("出现「无法找到服务器」或频繁卡顿时可尝试替换线路。证书异常的线路会在本次运行中自动屏蔽。快速加载模式跳过部分预检直接起播，可能因 CDN 报错。")
            }

            Section {
                Toggle("默认开启弹幕", isOn: $settings.danmakuEnabled)
                Picker("字号", selection: $settings.danmakuFontSize) {
                    ForEach([32.0, 36, 42, 48, 56], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                Picker("不透明度", selection: $settings.danmakuOpacity) {
                    ForEach([0.3, 0.5, 0.7, 0.85, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
                Picker("速度", selection: $settings.danmakuDuration) {
                    Text("慢").tag(12.0)
                    Text("适中").tag(9.0)
                    Text("快").tag(6.0)
                }
                Picker("显示区域", selection: $settings.danmakuArea) {
                    Text("1/4 屏").tag(0.25)
                    Text("半屏").tag(0.5)
                    Text("3/4 屏").tag(0.75)
                    Text("全屏").tag(1.0)
                }
                Picker("密度", selection: $settings.danmakuDensity) {
                    Text("稀疏").tag(0.25)
                    Text("较少").tag(0.5)
                    Text("正常").tag(1.0)
                }
                Toggle("合并重复弹幕", isOn: $settings.danmakuMerge)
                Toggle("智能防挡（人物不被弹幕遮挡）", isOn: $settings.danmakuMask)
            } header: {
                Text("弹幕")
            }

            Section {
                Picker("按权重屏蔽", selection: $settings.danmakuMinWeight) {
                    Text("不屏蔽").tag(0)
                    ForEach(Array(stride(from: 2, through: 10, by: 2)), id: \.self) { Text("\($0) 级以下").tag($0) }
                }
                Toggle("滚动弹幕", isOn: $settings.danmakuShowScroll)
                Toggle("顶部弹幕", isOn: $settings.danmakuShowTop)
                Toggle("底部弹幕", isOn: $settings.danmakuShowBottom)
                Toggle("彩色弹幕", isOn: $settings.danmakuShowColored)
                Toggle("同步账号屏蔽词", isOn: $settings.danmakuSyncAccountFilter)
                NavigationLink("本地屏蔽词（\(settings.danmakuBlockWords.count)）") {
                    WordListEditor(title: "弹幕屏蔽词", words: $settings.danmakuBlockWords)
                }
            } header: {
                Text("弹幕屏蔽")
            } footer: {
                Text("权重是 B 站对弹幕质量的评分（0–11），等级越低越可能是刷屏或低质内容。")
            }

            Section {
                Toggle("显示醒目留言", isOn: $settings.liveShowSuperChat)
                Toggle("直播使用 VLC 播放器（FLV）", isOn: $settings.liveForceVLC)
            } header: {
                Text("直播")
            } footer: {
                Text("默认使用系统播放器播放 HLS 直播流；个别直播间卡顿或无法播放时可改用 VLC（优先 FLV 流）。VLC 播放时：按下打开选项，向右切换线路。")
            }

            Section {
                Toggle("自动跳过恰饭/广告片段", isOn: $settings.skipSponsorSegments)
            } header: {
                Text("片段跳过")
            } footer: {
                Text("片段数据来自社区维护的 BilibiliSponsorBlock，仅在开启后按视频号查询。")
            }

            Section("字幕") {
                Toggle("自动显示字幕", isOn: $settings.showSubtitles)
                Toggle("没有人工字幕时使用 AI 字幕", isOn: $settings.subtitleAIDefault)
                NavigationLink("字幕屏蔽词（\(settings.subtitleBlockWords.count)）") {
                    WordListEditor(title: "字幕屏蔽词", words: $settings.subtitleBlockWords)
                }
            }

            Section {
                // Every signed-in account, removable here as well as by long-pressing its avatar on 我的.
                ForEach(accounts.accounts) { account in
                    Button {
                        pendingRemoval = account
                    } label: {
                        HStack(spacing: Theme.Spacing.s) {
                            Avatar(url: account.face, size: 44)
                            Text(account.name.isEmpty ? "UID \(String(account.mid))" : account.name)
                            if account.mid == accounts.currentID {
                                Text("当前").font(Theme.Font.caption).foregroundStyle(Theme.accent)
                            }
                            Spacer()
                            Text("移除").foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("通过 iCloud 钥匙串同步登录信息", isOn: $settings.iCloudSync)
                NavigationLink("iCloud 同步状态") { ICloudStatusView() }
                if !accounts.accounts.isEmpty {
                    Button("清空所有登录信息", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("账户")
            } footer: {
                if accounts.accounts.isEmpty { Text("在「我的」里扫码登录。") }
            }

            Section {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                LabeledContent("许可证", value: "GPL-3.0")
                LabeledContent("源代码", value: "github.com/CurryFishBalls9527/DanmuTV")
                NavigationLink("开源许可与致谢") { LicensesView() }
            } header: {
                Text("关于")
            } footer: {
                Text("Danmu TV 是非官方的开源客户端，与哔哩哔哩没有任何关联。\n小技巧：在任何列表里按遥控器的「播放/暂停」键可以刷新；再次点按当前标签页也会刷新。")
            }
        }
        .ambient("")
        .confirmationDialog("清空所有登录信息？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { accounts.removeAll() }
        }
        .confirmationDialog("移除账户", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval)
        { account in
            Button("移除 \(account.name.isEmpty ? "UID \(String(account.mid))" : account.name)", role: .destructive) { accounts.remove(account.mid) }
        }
    }
}

/// Add/remove a list of words (block lists).
struct WordListEditor: View {
    let title: String
    @Binding var words: [String]
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                TextField("添加屏蔽词", text: $draft)
                    .onSubmit(add)
            }
            Section {
                if words.isEmpty {
                    Text("还没有屏蔽词").foregroundStyle(.secondary)
                }
                ForEach(words, id: \.self) { word in
                    Button(role: .destructive) {
                        words.removeAll { $0 == word }
                    } label: {
                        HStack {
                            Text(word)
                            Spacer()
                            Image(systemName: "trash")
                        }
                    }
                }
            } footer: {
                Text("点按一项即可删除。")
            }
        }
        .navigationTitle(title)
    }

    private func add() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !word.isEmpty, !words.contains(word) else { return }
        words.append(word)
    }
}

struct CustomHostEditor: View {
    @Binding var host: String
    @State private var draft = ""
    @State private var invalid = false

    /// Accepts "host", "https://host/path" → "host"; rejects anything that isn't a hostname.
    static func hostname(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        let host = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.host ?? ""
        let valid = host.contains(".") && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return valid ? host : nil
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("例如 upos-sz-mirrorcos.bilivideo.com", text: $draft)
                    .onSubmit {
                        let value = Self.hostname(from: draft)
                        if draft.trimmingCharacters(in: .whitespaces).isEmpty || value != nil {
                            host = value ?? ""
                            dismiss()
                        } else {
                            invalid = true
                        }
                    }
                if invalid { Text("请输入域名，例如 upos-sz-mirrorcos.bilivideo.com").foregroundStyle(.orange) }
            } footer: {
                Text("只替换 B 站官方 upos 线路的域名，原线路仍作为备用。留空并提交即关闭替换。")
            }
        }
        .navigationTitle("自定义线路")
        .onAppear { draft = host }
    }
}

/// 查看 iCloud 状态 / 清空 iCloud 中的账户信息.
struct ICloudStatusView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(AppSettings.self) private var settings
    @State private var status = AccountStore.SyncStatus(local: 0, synced: 0)
    @State private var confirmClear = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("同步", value: settings.iCloudSync ? "已开启" : "已关闭")
                LabeledContent("iCloud 账户", value: FileManager.default.ubiquityIdentityToken != nil ? "已登录" : "未登录或不可用")
                LabeledContent("本设备保存的账户", value: "\(status.local)")
                LabeledContent("iCloud 钥匙串中的账户", value: "\(status.synced)")
                LabeledContent("当前账户", value: accounts.current?.name ?? "未登录")
            } footer: {
                Text("登录信息通过 iCloud 钥匙串在同一 Apple ID 的 Apple TV 之间同步；需要在系统设置中登录 iCloud 并开启钥匙串。当前选中的账户只保存在本机，不会互相覆盖。设置项不同步（需要付费开发者账号开启 iCloud 键值存储）。")
            }
            Section {
                Button("重新读取") { refresh() }
                Button("清空 iCloud 中的账户信息", role: .destructive) { confirmClear = true }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("iCloud 同步状态")
        .onAppear { refresh() }
        .confirmationDialog("清空 iCloud 中的账户信息？本机账户保留，并关闭本机的 iCloud 同步。其他仍开启同步的 Apple TV 会再次上传，请先在那些设备上关闭同步。", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                accounts.clearICloudAccounts()
                refresh()
                message = "已清空 iCloud 中的账户信息"
            }
        }
    }

    private func refresh() {
        status = accounts.syncStatus()
    }
}

/// 可切换的 App 图标.
struct AppIconPicker: View {
    private static let icons: [(name: String?, title: String, preview: String)] = [
        (nil, "经典", "Classic"), ("Midnight", "午夜", "Midnight"), ("Light", "浅色", "Light"),
    ]
    @State private var current = UIApplication.shared.alternateIconName
    @State private var error: String?

    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 60) {
                ForEach(Self.icons, id: \.title) { icon in
                    Button {
                        Task { await select(icon.name) }
                    } label: {
                        VStack(spacing: 16) {
                            ZStack {
                                Image("IconPreview-\(icon.preview)-back").resizable()
                                Image("IconPreview-\(icon.preview)-front").resizable()
                            }
                            .aspectRatio(400 / 240, contentMode: .fit)
                            .frame(width: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            HStack {
                                Text(icon.title)
                                if current == icon.name { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                    .buttonStyle(.card)
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("App 图标")
    }

    private func select(_ name: String?) async {
        guard UIApplication.shared.supportsAlternateIcons else {
            error = "当前设备不支持更换图标"
            return
        }
        do {
            try await UIApplication.shared.setAlternateIconName(name)
            current = name
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 开源许可与致谢: what DanmuTV links and builds on (THIRD_PARTY_NOTICES.md in the repository has the full text).
private struct LicensesView: View {
    private let items: [(name: String, license: String, note: String)] = [
        ("Danmu TV", "GPL-3.0", "github.com/CurryFishBalls9527/DanmuTV。非官方客户端，与哔哩哔哩没有任何关联；视频、弹幕、评论等内容版权归哔哩哔哩及其创作者所有。"),
        ("VLCKit", "LGPL-2.1", "code.videolan.org/videolan/VLCKit — FLV 直播与本地文件播放（含 GPL-2.0-or-later 的 libVLC 模块）。"),
        ("AMSMB2 / libsmb2", "LGPL-2.1", "github.com/amosavian/AMSMB2 — SMB 共享浏览与播放。"),
        ("BilibiliSponsorBlock", "社区数据", "github.com/hanydd/BilibiliSponsorBlock — 开启「片段跳过」时查询的片段数据。"),
        ("NeoBV", "MIT", "github.com/b1ackmarket/NeoBV — 新版投屏协议的参考。Copyright (c) 2022 aaa1115910."),
        ("哔哩必连协议分析", "文章", "xfangfang.cn/028 — 旧版 NVA 投屏协议。"),
    ]

    var body: some View {
        List {
            ForEach(items, id: \.name) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.name).font(Theme.Font.headline)
                        Spacer()
                        Text(item.license).font(Theme.Font.meta).foregroundStyle(Theme.textSecondary)
                    }
                    Text(item.note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 8)
                .focusable()
            }
        }
        .navigationTitle("开源许可与致谢")
    }
}
