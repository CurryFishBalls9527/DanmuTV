<div align="center">

<img src="DanmuTV/Resources/Assets.xcassets/App%20Icon%20%26%20Top%20Shelf%20Image.brandassets/Top%20Shelf%20Image%20Wide.imageset/TopShelf-wide.jpg" width="640" alt="Danmu TV">

**非官方的 Apple TV 哔哩哔哩客户端**

原生 tvOS 体验 · 4K / HDR / 杜比视界 · 流畅弹幕 · 手机投屏

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-tvOS%2017%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
[![CI](https://github.com/CurryFishBalls9527/DanmuTV/actions/workflows/ci.yml/badge.svg)](https://github.com/CurryFishBalls9527/DanmuTV/actions/workflows/ci.yml)

[English](README.en.md) · [功能](#功能) · [截图](#截图) · [安装](#从源码安装) · [免责声明](#免责声明)

</div>

> [!IMPORTANT]
> Danmu TV 是**非官方**的开源项目，与哔哩哔哩（上海宽娱数码科技有限公司）**没有任何关联**，也未获其认可。
> 本项目**从未在 App Store、TestFlight 或任何平台上架或收费**，也不提供任何安装包；如果有人以收费方式提供本项目，那不是我们。
> **请只从本仓库源码自行编译安装。** 他人打包的安装包可能被篡改，而本应用需要登录你的哔哩哔哩账号，存在盗号风险。

---

## 功能

### 浏览
- **推荐 / 热门 / 排行榜 / 动态 / 直播 / 番剧 / 搜索 / 我的**，为遥控器设计的焦点体验
- 首页大图舞台、横向分区、无限滚动；列表内按 ⏯ 刷新
- 番剧 / 影视：热门榜、时间表、我的追番、OP / ED 自动跳过
- 视频详情：分 P、合集、相关推荐、**热门评论**（含回复与点赞）
- 卡片长按菜单：稍后再看、不感兴趣、去 UP 主页
- Top Shelf：热门与**继续观看**

### 播放
- 原生 `AVPlayerViewController`：DASH 在本地实时转为 HLS，按带宽自动切换清晰度
- 4K / 8K、HEVC / AV1、HDR10 / HLG、杜比视界、杜比全景声 / FLAC
- 自动匹配动态范围与帧率；CDN 策略与自动切换线路
- 继续播放、连续播放、播完自动播放相关推荐
- **长按确认键临时 2× / 3× 倍速**，单集循环、镜像、章节、字幕（含 AI 字幕）
- 社区片段数据库跳过恰饭片段（[BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)，默认关闭）

### 弹幕
- CALayer 渲染、后台光栅化，长视频高密度弹幕也不卡（在初代 Apple TV 4K 上实测）
- 字号、不透明度、速度、区域、密度、合并重复、按权重 / 类型 / 关键词屏蔽，同步账号屏蔽词
- **智能防挡**：使用 B 站提供的人像蒙版，弹幕从人物身后穿过

### 直播
- HLS 直播（AVPlayer）与 FLV（VLC），直播弹幕与醒目留言

### 手机投屏
- 在哔哩哔哩手机 App 里点「投屏」，选择 Danmu TV 即可在电视上播放：识别视频本身（不是转发视频地址），
  弹幕、历史、清晰度都走 Danmu TV 自己的播放器；手机端的暂停、进度、倍速、退出都同步
- 兼容新版官方 App 的 UPnP + NirvanaControl 投屏，以及较早的 NVA 协议；其他 DLNA 应用投来的普通视频地址也能播放

### 其他
- 扫码登录、最多 5 个账户，登录信息通过 iCloud 钥匙串在多台 Apple TV 之间同步
- SMB 共享浏览与本地播放
- 可切换的 App 图标；无任何第三方统计或崩溃上报

> 界面目前只有简体中文。

## 截图

| 首页 | 番剧 |
|---|---|
| ![首页](docs/screenshots/home.jpg) | ![番剧](docs/screenshots/bangumi.jpg) |
| **视频详情** | **热门评论** |
| ![视频详情](docs/screenshots/video.jpg) | ![热门评论](docs/screenshots/comments.jpg) |
| **评论回复** | **播放器** |
| ![评论回复](docs/screenshots/comment-thread.jpg) | ![播放器](docs/screenshots/player.jpg) |
| **排行榜** | **搜索** |
| ![排行榜](docs/screenshots/ranking.jpg) | ![搜索](docs/screenshots/search.jpg) |

<sub>截图来自未登录的模拟器；其中的视频、番剧、封面与评论内容版权归各自所有者，评论用户信息已模糊处理。</sub>

## 从源码安装

Danmu TV 不在 App Store 上架，需要自己编译安装到 Apple TV。

**需要**
- 一台 Mac，安装 Xcode 26 或更高版本（CI 使用 Xcode 26，开发使用 Xcode 27）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- Apple TV（tvOS 17+），与 Mac 在同一网络
- Apple ID。免费账号签名 7 天后过期需要重新安装，且不支持 App Group（在 `Local.xcconfig` 里设 `DANMUTV_APP_GROUP = NO`，Top Shelf 只显示热门）；付费开发者账号（每年 99 美元）一年有效，功能完整

**步骤**

```sh
git clone https://github.com/CurryFishBalls9527/DanmuTV.git
cd DanmuTV
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填入你的 Team ID 和 Bundle ID
xcodegen generate
open DanmuTV.xcodeproj
```

1. 在 `Config/Local.xcconfig` 里设置 `DEVELOPMENT_TEAM`（Xcode › Settings › Accounts 里能看到）和一个属于你的
   `APP_BUNDLE_ID`，例如 `com.yourname.DanmuTV`。
2. 在 Apple TV 上打开「设置 › 遥控器与设备 › 遥控器 App 与设备」，在 Xcode 的 Devices 窗口里配对。
3. 选择 `DanmuTV` scheme 和你的 Apple TV，⌘R 运行。

只想在模拟器里看看：跳过第 1、2 步，直接选 tvOS 模拟器运行即可。

## 已知限制

- 界面只有简体中文。
- HDR / 杜比视界 / 全景声和显示匹配已实现，但只在少量设备上验证过，欢迎反馈。
- 投屏只在 Danmu TV 打开（在前台）时可用，这是 tvOS 对后台网络的限制。
- 投屏接收不需要配对：同一局域网内的设备都可以让电视开始、暂停或停止播放。不需要时可在「设置 › 投屏」关闭。
- 智能防挡依赖 B 站提供的人像蒙版，只有部分视频有；蒙版质量取决于 B 站的数据。
- 未登录时 B 站只返回前 3 条热门评论。
- 接口不是官方公开的，B 站调整后可能暂时失效。

## 开发

```sh
cd Packages/BiliKit && swift test     # 网络层、解析、签名、弹幕、投屏协议等单元测试
scripts/sim.sh "danmutv://tab/recommend"   # 编译并在模拟器里静音启动
```

- `Packages/BiliKit`：与界面无关的部分（API、签名、DASH→HLS、弹幕、投屏协议），可以在 macOS 上直接 `swift test`
- `DanmuTV/`：SwiftUI 界面与播放器；`TopShelf/`：Top Shelf 扩展
- `DanmuTVUITests/`：用遥控器操作的界面测试，会访问真实接口，请按需运行

**架构速览**

- **播放**：B 站返回 DASH（音视频分离的 fMP4）。`DashResourceLoader` 通过 `AVAssetResourceLoader` 的自定义 scheme，
  根据 `sidx` 索引实时生成 HLS 主列表和分片列表交给 `AVPlayer`，从而得到原生播放器、自适应码率和 HDR / 杜比视界。
- **弹幕**：按 6 分钟分段拉取 protobuf，过滤 / 合并后进入时间轴；`DanmakuRasterizer` 在后台线程把文字光栅化成位图，
  主线程只移动 `CALayer`。智能防挡把 B 站的 SVG 人像蒙版预先画成小位图，作为弹幕层的 mask。
- **投屏**：`CastReceiver` 在前台时用 SSDP 宣告自己，在 9958 端口同时提供 UPnP SOAP（AVTransport / NirvanaControl 等）
  和旧版 NVA 二进制协议；协议解析（帧编解码、`_nva_ext_` 解密、SOAP）都在 BiliKit 里并有单元测试。

欢迎贡献，请先看 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 免责声明

- Danmu TV 是独立的、**非官方**的开源项目，与哔哩哔哩（上海宽娱数码科技有限公司）及其关联公司**没有任何关联**，
  未获得其授权或认可。「哔哩哔哩」「bilibili」等名称和标识是其各自所有者的商标，此处仅用于说明兼容性。
- 所有视频、番剧、直播、弹幕、评论等内容的版权归哔哩哔哩及各内容创作者所有。Danmu TV 不托管、不缓存、不分发任何内容，
  只是以登录用户本人的账号访问哔哩哔哩已向其提供的内容。
- Danmu TV **不绕过**任何付费、会员、地区或版权限制，不破解任何 DRM。大会员内容需要你自己的大会员账号。
- 本项目使用的接口并非官方公开接口，随时可能变化或失效；使用本软件可能违反哔哩哔哩的用户协议，**风险由使用者自行承担**。
- 使用第三方客户端可能触发哔哩哔哩的风控，导致账号功能受限甚至封禁；因使用本软件造成的账号问题、数据丢失或其他损失，作者不承担责任。
- Danmu TV 以 GPL-3.0 发布。作者不出售本项目，也不提供任何收费版本或服务；任何收费提供本项目的行为都与作者无关。
  我们希望它只被用于学习与个人用途。
- 登录凭证只保存在你的设备钥匙串中（开启 iCloud 钥匙串时在你自己的设备之间同步），只发送给哔哩哔哩。本项目不收集任何数据，
  也没有统计或崩溃上报。唯一的第三方请求：开启「片段跳过」（默认关闭）后，会把正在播放视频的 BV 号发送给
  [BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)（bsbsb.top）查询片段，不包含任何账号信息。
- 软件按「原样」提供，不附带任何形式的担保，详见 [LICENSE](LICENSE)。
- 为了与官方手机 App 的投屏协议互通，Danmu TV 在局域网的 UPnP 应答里使用了官方 TV App 的包名、厂商名等协议标识；
  部分接口需要使用社区公开流传的官方客户端签名参数。这些仅用于兼容，不代表与哔哩哔哩有任何关联；
  设备列表中 Danmu TV 始终显示为「Danmu TV · …」。
- 如果你是权利人并认为本项目侵犯了你的权益，请发邮件至 [ChaosStudio599@gmail.com](mailto:ChaosStudio599@gmail.com)，我们会尽快处理。

## 致谢

- [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)：Apple TV 上开源 B 站客户端的先行者
- [NeoBV](https://github.com/b1ackmarket/NeoBV)：新版投屏协议的参考实现（MIT）
- xfangfang 的[《分析Bilibili客户端的“哔哩必连”协议》](https://www.xfangfang.cn/028)
- [VLCKit](https://code.videolan.org/videolan/VLCKit)、[AMSMB2](https://github.com/amosavian/AMSMB2)、
  [BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)
- 完整的第三方许可与说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

本项目在 [Claude Code](https://claude.com/claude-code) 的协助下开发。

## 许可证

[GNU General Public License v3.0](LICENSE)。你可以自由使用、修改和再分发，但分发修改版本时必须以相同许可证公开源代码。
