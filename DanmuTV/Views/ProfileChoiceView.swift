import BiliKit
import SwiftUI

/// tvOS 多用户: 「谁在看？」 the first time an Apple TV user opens the app. The profile picked is remembered for that
/// user, so switching users in Control Center switches Bilibili accounts too.
struct ProfileChoiceView: View {
    @Environment(AccountStore.self) private var accounts
    @FocusState private var focused: Int?

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Text("谁在看？").font(Theme.Font.display)
            Text("为这位 Apple TV 用户选择 B 站账号。以后在控制中心切换到这位用户时，会自动使用这个账号。")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                ForEach(accounts.accounts) { account in
                    Button {
                        accounts.profileChosen(account.mid)
                    } label: {
                        VStack(spacing: 16) {
                            Avatar(url: account.face, size: 200)
                            Text(account.name.isEmpty ? "UID \(String(account.mid))" : account.name)
                                .font(Theme.Font.card)
                                .lineLimit(1)
                        }
                        .frame(width: 260)
                    }
                    .buttonStyle(.borderless)
                    .focused($focused, equals: account.mid)
                    .accessibilityIdentifier("profile.\(account.mid)")
                }
                if accounts.canAddProfile {
                    Button {
                        accounts.loginAfterProfileChoice = true
                        accounts.profileChosen(nil)
                    } label: {
                        VStack(spacing: 16) {
                            Image(systemName: "plus")
                                .font(.system(size: 64, weight: .medium))
                                .frame(width: 200, height: 200)
                                .background(Theme.surfaceRaised, in: Circle())
                            Text("登录其他账号").font(Theme.Font.card).lineLimit(1)
                        }
                        .frame(width: 260)
                    }
                    .buttonStyle(.borderless)
                    .focused($focused, equals: 0)
                    .accessibilityIdentifier("profile.add")
                }
            }
            .padding(.top, Theme.Spacing.l)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.base.ignoresSafeArea())
        .onAppear { focused = accounts.currentID ?? accounts.accounts.first?.mid ?? 0 }
        // Menu keeps the profile shown now and doesn't ask again.
        .onExitCommand { accounts.profileChosen(nil) }
    }
}
