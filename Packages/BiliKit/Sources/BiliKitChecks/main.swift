import BiliKit
import Foundation

// Live smoke test against real Bilibili endpoints (logged out). Offline logic lives in BiliKitTests.
//   swift run BiliKitChecks --network
// Keep runs rare: Bilibili throttles an IP (HTTP 412) after bursts of requests.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)")
    }
}

if CommandLine.arguments.contains("--network") {
    print("Network (logged out)")
    do {
        let popular = try await API.popular(page: 1, anonymous: true)
        check(!popular.items.isEmpty && !popular.items[0].bvid.isEmpty, "popular list (\(popular.items.count) items)")
        let rec = try await API.recommend(freshIndex: 1)
        check(!rec.isEmpty, "recommend feed (\(rec.count) items)")
        let rank = try await API.ranking(categoryID: 0)
        check(!rank.isEmpty, "ranking (\(rank.count) items)")
        let detail = try await API.videoDetail(bvid: "BV1GJ411x7h7")
        check(detail.item.cid > 0 && !detail.pages.isEmpty, "video detail: \(detail.item.title)")
        let stream = try await API.progressiveStream(bvid: detail.item.bvid, cid: detail.item.cid)
        check(stream.url.host?.contains("bilivideo") == true, "progressive stream \(stream.qualityName)")
        let related = try await API.related(bvid: detail.item.bvid)
        check(!related.isEmpty, "related videos (\(related.count))")
        let qr = try await API.tvQRCode()
        check(qr.url.hasPrefix("https://") && !qr.authCode.isEmpty, "TV QR code")
        let state = try await API.tvQRPoll(authCode: qr.authCode)
        if case .waiting = state { check(true, "TV QR poll → waiting") } else { check(false, "TV QR poll → waiting") }
        let nav = try await API.nav()
        check(nav["isLogin"].bool == false, "nav logged out")
    } catch {
        failures += 1
        print("  ✗ network error: \(error)")
    }
}

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
