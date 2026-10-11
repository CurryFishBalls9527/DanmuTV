# Third-party notices

Danmu TV itself is licensed under the GNU General Public License v3.0 (see `LICENSE`). It links the libraries
below and draws on the work listed under *References*.

## Libraries

| Library | Use | License |
|---|---|---|
| [VLCKit](https://code.videolan.org/videolan/VLCKit) via [vlckit-spm](https://github.com/tylerjonesio/vlckit-spm) | FLV live streams and local files AVPlayer can't open | LGPL-2.1 |
| [AMSMB2](https://github.com/amosavian/AMSMB2) with [libsmb2](https://github.com/sahlberg/libsmb2) | SMB (network share) browsing and playback | LGPL-2.1 (AMSMB2's own code is MIT; it links libsmb2 statically) |

Both are fetched by Swift Package Manager at build time; their sources and license texts are available from the
links above. LGPL-2.1 permits use from a GPL-3.0 application. The VLCKit binary also contains libVLC modules under
GPL-2.0-or-later, which is compatible with GPL-3.0.

## Data and services

- **Bilibili** web / TV endpoints, used with the signed-in user's own account. Not affiliated; see the disclaimer
  in `README.md`.
- **[BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)** (`bsbsb.top`): community-submitted
  sponsor / intro segments, queried only when 片段跳过 is switched on. Data belongs to its contributors under that
  project's terms.

## References

- **[NeoBV](https://github.com/b1ackmarket/NeoBV)** (MIT License, Copyright (c) 2022 aaa1115910): how current
  Bilibili apps cast over UPnP — the NirvanaControl service and its actions, the `_nva_ext_` encoding — and the
  shape of the SetAVTransportURI request in `CastTests.testOfficialProjectionIdentityIsDecoded` (its payload is
  synthetic).
  Danmu TV's implementation is its own Swift code.

  > Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
  > documentation files (the "Software"), to deal in the Software without restriction, including without limitation
  > the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
  > to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above
  > copyright notice and this permission notice shall be included in all copies or substantial portions of the
  > Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

- **[分析Bilibili客户端的“哔哩必连”协议](https://www.xfangfang.cn/028)** by xfangfang: the older NVA cast protocol
  (SSDP, `SETUP /projection`, binary frames).
- **[ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)** (GPL-2.0): feature comparison and
  protocol facts only; no code was copied.
