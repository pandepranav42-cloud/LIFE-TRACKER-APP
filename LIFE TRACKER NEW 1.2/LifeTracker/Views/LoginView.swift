import SwiftUI
import SwiftData
import AuthenticationServices

// MARK: - Root gate

/// The app only opens after signing in. Signing out anywhere returns here.
struct RootView: View {
    @ObservedObject private var accounts = AccountStore.shared
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if accounts.isLoggedIn {
                ContentView()
                    // Life AI floats above every page — Today through the
                    // GitHub console — rather than living on one of them.
                    .lifeAIOverlay()
                    .transition(.opacity)
                    // After (re)connecting Google, back up anything not yet in Drive.
                    .task(id: accounts.googleEmail) {
                        if DriveSync.shared.isActive {
                            await DriveSync.shared.backupAll(context: context)
                        }
                    }
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: accounts.isLoggedIn)
        .onAppear {
            accounts.refreshAppleState()
            BackgroundCoordinator.shared.scheduleRefresh(context, after: 0.5)
        }
        // Widgets + notifications stay current in the background.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            BackgroundCoordinator.shared.scheduleRefresh(context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { BackgroundCoordinator.shared.scheduleRefresh(context, after: 0) }
        }
    }
}

// MARK: - Login screen

struct LoginView: View {
    @ObservedObject private var accounts = AccountStore.shared
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.colorScheme) private var colorScheme

    @State private var googleBusy = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    header(compact: geo.size.width < 600)
                    card
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 20)
                        .padding(.top, -56)
                    footer
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 28)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(Palette.surface.ignoresSafeArea())
        .blendedToolbar()
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "E9B9A7"), Color(hex: "D99A86"), Color(hex: "F2D9B8")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.45), .clear],
                           center: .init(x: 0.2, y: 0.3), startRadius: 10, endRadius: 320)
            HStack(spacing: compact ? 40 : 90) {
                Image(systemName: "book.closed.fill").font(.system(size: 34, weight: .light))
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 52, weight: .light))
                Image(systemName: "leaf.fill").font(.system(size: 30, weight: .light))
            }
            .foregroundStyle(.white.opacity(0.35))
            .offset(y: -18)
        }
        .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0))
        .frame(height: compact ? 190 : 240)
        .clipped()
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 18) {
            AppLogo(size: 96)
                .padding(.top, -70)

            VStack(spacing: 6) {
                Text("LifeTracker").font(.mono(28, .bold))
                Text("sign in to your study & life space")
                    .font(.mono(12)).italic()
                    .foregroundStyle(Palette.mutedText)
            }

            // Google
            Button {
                googleBusy = true
                Task {
                    await accounts.signInWithGoogle(using: webAuth, asLogin: true)
                    googleBusy = false
                }
            } label: {
                HStack(spacing: 10) {
                    if googleBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        GoogleMark()
                    }
                    Text(googleBusy ? "Opening Google…" : "Continue with Google")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(.primary)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(googleBusy)

            // Guest
            Button {
                accounts.signInAsGuest()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 17))
                    Text("Continue as guest")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(Palette.accent)
                .background(Palette.callout, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(googleBusy)

            Text("As a guest everything works and stays on this device. Drive backup and Calendar sync need a Google account — you can connect one later in Settings without losing anything.")
                .font(.mono(11))
                .foregroundStyle(Palette.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let error = accounts.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(24)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.06), radius: 24, y: 10)
        .animation(.easeInOut(duration: 0.2), value: accounts.lastError)
    }

    private var footer: some View {
        Text("Your data stays on this device. Signing in with Google also lets LifeTracker back up the files you add to your Google Drive and add your marked dates to Google Calendar.")
            .font(.caption)
            .foregroundStyle(Palette.mutedText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

}

/// Google's official "G" mark, loaded from the image you add to the project
/// (see README: download it from Google's Sign-In branding page and add it
/// as "GoogleG"). Falls back to a neutral symbol until it's added.
private struct GoogleMark: View {
    var body: some View {
        if let img = PlatformImage(named: "GoogleG") {
            Image(platformImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.mutedText)
                .frame(width: 20, height: 20)
        }
    }
}

