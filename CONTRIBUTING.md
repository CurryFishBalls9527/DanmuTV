# Contributing to Danmu TV

感谢你愿意参与！Thanks for helping out. Issues and pull requests are welcome in Chinese or English.

## Before you start

- **Bugs**: search existing issues first, then open one with the bug template. Include your tvOS version, Apple TV
  model, Danmu TV commit, and the steps that reproduce it. A video BV number helps a lot for playback issues.
- **Features**: open an issue to discuss it before writing a large change, so we can agree on the approach.
- **Out of scope**: anything that bypasses paywalls, membership, region or copyright restrictions, breaks DRM, or
  downloads content for redistribution. Such PRs will be closed.

## Setting up

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # only needed for a real Apple TV
xcodegen generate
open DanmuTV.xcodeproj
```

`DanmuTV.xcodeproj` is generated from `project.yml`; don't commit it. Add new files on disk, then rerun
`xcodegen generate`.

## Project layout

| Path | What |
|---|---|
| `Packages/BiliKit` | UI-free core: API client and signing, DASH→HLS, danmaku parsing and layout, cast protocols, models |
| `DanmuTV/` | SwiftUI app: views, player, settings, accounts |
| `TopShelf/` | Top Shelf extension |
| `DanmuTVUITests/` | Siri Remote-driven UI tests (live API) |
| `Config/` | Signing settings (`Local.xcconfig` is yours and git-ignored; `DANMUTV_APP_GROUP = NO` for free teams) |

## Tests

```sh
cd Packages/BiliKit && swift test
```

- Logic that can live in BiliKit should, with unit tests. Prefer recorded API responses in
  `Tests/BiliKitTests/Fixtures` over live calls.
- UI changes: run the relevant `DanmuTVUITests` in the tvOS simulator and check the screenshots. They hit the live
  API, so run only what you touched:
  `xcodebuild test -project DanmuTV.xcodeproj -scheme DanmuTVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -only-testing:DanmuTVUITests/<Suite>`
- Simulator playback is muted by the tests (`-muted YES`); please keep it that way.
- UI tests use real videos (BV ids in the test files). A failure there is often content or network churn (a video
  removed or region-locked, rate limiting) rather than a regression; check the screenshots before chasing it.
- `swift run BiliKitChecks --network` (in `Packages/BiliKit`) is a quick live smoke test of the main endpoints.

## Style

- Match the surrounding code: Swift API Design Guidelines, 4-space indentation, comments that explain *why*.
- Every screen must be fully usable with the Siri Remote: no focus traps, no lost focus, sensible defaults.
- No third-party analytics, tracking or crash reporting.
- Keep user-facing text in Simplified Chinese, consistent with the existing wording.

## Pull requests

- One topic per PR, with a clear description of what changed and how you tested it (screenshots for UI).
- `swift test` must pass; CI builds the app and runs the unit tests.
- By contributing you agree that your contribution is licensed under GPL-3.0, the project's license.
