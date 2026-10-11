import BiliKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Scan-to-sign-in. The QR code is the one bright object on the screen, the steps read beside it.
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var accounts

    private enum Status: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case failed(String)
        case done
    }

    @State private var qrImage: UIImage?
    @State private var status: Status = .loading
    @State private var attempt = 0
    @FocusState private var refreshFocused: Bool

    var body: some View {
        ZStack {
            // Still glows, no blur: the sheet already sits on the system's blurred material.
            Theme.base.opacity(0.6)
            RadialGradient(colors: [Theme.accent.opacity(0.35), .clear], center: UnitPoint(x: 0.18, y: 0.3), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(red: 0.14, green: 0.5, blue: 0.9).opacity(0.25), .clear], center: UnitPoint(x: 0.85, y: 0.9), startRadius: 0, endRadius: 900)

            HStack(spacing: 120) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                        .fill(.white)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 80, y: 10)
                        .shadow(color: .black.opacity(0.5), radius: 50, y: 30)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .padding(34)
                            .opacity(status == .expired ? 0.12 : 1)
                            .animation(Theme.motion, value: status)
                    } else {
                        ProgressView().tint(.black)
                    }
                    if status == .expired {
                        VStack(spacing: 12) {
                            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 60, weight: .medium))
                            Text("二维码已过期").font(Theme.Font.headline)
                        }
                        .foregroundStyle(.black)
                    }
                }
                .frame(width: 540, height: 540)

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text("Danmu TV").font(Theme.Font.headline).foregroundStyle(Theme.accent)
                    Text("扫码登录").font(Theme.Font.display)
                    if accounts.currentNeedsReLogin, let current = accounts.current {
                        Text("「\(current.name)」的登录已失效，请重新扫码。")
                            .font(Theme.Font.meta).foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        step(1, "打开哔哩哔哩手机 App")
                        step(2, "点右上角「扫一扫」，对准屏幕上的二维码")
                        step(3, "在手机上确认登录")
                    }
                    .font(Theme.Font.body)
                    .padding(.top, Theme.Spacing.xs)
                    statusLabel
                        .font(Theme.Font.headline)
                        .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 12)
                        .background(Theme.surfaceRaised, in: Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                        .animation(Theme.motion, value: status)
                        .padding(.top, Theme.Spacing.xs)
                    if !accounts.canAddProfile {
                        Text("已达到 \(AccountStore.maxProfiles) 个账户上限，请先移除一个账户。")
                            .font(Theme.Font.meta).foregroundStyle(.orange)
                    }
                    Button("刷新二维码", systemImage: "arrow.clockwise") { attempt += 1 }
                        .buttonBorderShape(.capsule)
                        .focused($refreshFocused)
                        .padding(.top, Theme.Spacing.xs)
                }
                .frame(width: 780, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        // The only control on the sheet; focus lands on it so Menu / Select always have a target.
        .defaultFocus($refreshFocused, true)
        .task(id: attempt) { await runLogin() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(verbatim: "\(n)")
                .font(Theme.Font.badge)
                .frame(width: 40, height: 40)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(.white)
            Text(text).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .loading: Label("正在获取二维码…", systemImage: "hourglass")
        case .waiting: Label("等待扫码", systemImage: "qrcode.viewfinder")
        case .scanned: Label("已扫码，请在手机上确认", systemImage: "iphone").foregroundStyle(.green)
        case .expired: Label("二维码已过期，请刷新", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
        case let .failed(message): Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        case .done: Label("登录成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func runLogin() async {
        status = .loading
        qrImage = nil
        do {
            let code = try await API.tvQRCode()
            qrImage = Self.qrCode(code.url)
            status = .waiting
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let state: QRLoginState
                do {
                    state = try await API.tvQRPoll(authCode: code.authCode)
                    consecutiveFailures = 0
                } catch let error where !BiliClient.isCancellation(error) && consecutiveFailures < 4 {
                    // Ride out brief network blips instead of abandoning the QR code.
                    consecutiveFailures += 1
                    continue
                }
                switch state {
                case .waiting: status = .waiting
                case .scanned: status = .scanned
                case .expired:
                    status = .expired
                    return
                case let .success(account):
                    await finish(account)
                    return
                }
            }
        } catch {
            if !BiliClient.isCancellation(error) { status = .failed(error.localizedDescription) }
        }
    }

    private func finish(_ account: Account) async {
        var account = account
        let isKnown = accounts.accounts.contains { $0.mid == account.mid }
        guard isKnown || accounts.canAddProfile else {
            status = .failed("已达到 \(AccountStore.maxProfiles) 个账户上限")
            return
        }
        // Fetch the profile with the new credentials without touching the shared active account.
        if let nav = try? await API.nav(as: account) {
            account.name = nav["uname"].stringValue
            account.face = nav["face"].stringValue
        }
        accounts.add(account)
        status = .done
        try? await Task.sleep(nanoseconds: 800_000_000)
        dismiss()
    }

    static func qrCode(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
