import Foundation
import SwiftUI
import Security
import CryptoKit
import AuthenticationServices

// MARK: - Keychain (tokens never go into UserDefaults)

enum Keychain {
    private static let service = "com.pranavpande.LifeTracker"

    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - App configuration (one-time developer setup)

enum AppConfig {
    /// Google OAuth client ID (Google Cloud Console → Credentials → OAuth client
    /// ID → type "iOS", bundle id com.pranavpande.LifeTracker; enable the
    /// Google Calendar API and Google Drive API). Paste it here once:
    static let googleClientID = "574999679423-512hndk6scaa3qqhvpajegrv6di5fbds.apps.googleusercontent.com"

    static var isGoogleConfigured: Bool {
        effectiveGoogleClientID.hasSuffix(".apps.googleusercontent.com")
    }

    /// The constant above, or a value saved by an earlier build of the app.
    static var effectiveGoogleClientID: String {
        let fromCode = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromCode.isEmpty { return fromCode }
        return (UserDefaults.standard.string(forKey: "googleClientID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Who is using the app right now. The app stays on the login screen until
/// one of these exists.
struct AuthSession: Codable, Equatable {
    /// `developer` is kept only so a session saved by an older build still
    /// decodes; it's shown as a guest and nothing creates one any more.
    enum Method: String, Codable { case apple, google, guest, developer }
    var method: Method
    var name: String
    var email: String?
    var signedInAt: Date = .now

    var methodTitle: String {
        switch method {
        case .apple: return "Apple"
        case .google: return "Google"
        case .guest, .developer: return "Guest"
        }
    }
    var icon: String {
        switch method {
        case .apple: return "apple.logo"
        case .google: return "g.circle.fill"
        case .guest, .developer: return "person.crop.circle.dashed"
        }
    }
    var isGuest: Bool { method == .guest || method == .developer }
}

// MARK: - Account store (Apple + Google)

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    // Apple
    @Published private(set) var appleUserID: String? = Keychain.get("apple.userID")
    @Published private(set) var appleName: String? = Keychain.get("apple.name")
    @Published private(set) var appleEmail: String? = Keychain.get("apple.email")

    // Google
    @Published private(set) var googleEmail: String? = Keychain.get("google.email")
    @Published var lastError: String?

    /// The signed-in session (nil = show the login screen).
    @Published private(set) var session: AuthSession? = AccountStore.loadSession()

    var isLoggedIn: Bool { session != nil }
    var isAppleSignedIn: Bool { appleUserID != nil }
    var isGoogleSignedIn: Bool { Keychain.get("google.refresh") != nil }
    /// Google scopes granted at sign-in (Drive needs a newer sign-in if missing).
    var hasDriveScope: Bool { (Keychain.get("google.scope") ?? "").contains("drive.file") }
    /// The Colab notebooks live in a *separate* Google connection, kept under
    /// its own Keychain keys. That's deliberate: your notebooks are often on a
    /// university account while Drive backup and Calendar stay on your personal
    /// one, and connecting one must never disturb the other.
    var colabEmail: String? { Keychain.get("colab.email") }
    var isColabConnected: Bool { Keychain.get("colab.refresh") != nil }

    private var mainScopes: String {
        ["openid", "email", "profile",
         "https://www.googleapis.com/auth/calendar.events",
         "https://www.googleapis.com/auth/drive.file"].joined(separator: " ")
    }
    private var colabScopes: String {
        ["openid", "email",
         "https://www.googleapis.com/auth/drive.readonly"].joined(separator: " ")
    }

    private init() {}

    // MARK: Session

    private static func loadSession() -> AuthSession? {
        guard let data = Keychain.get("auth.session")?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    @MainActor
    private func setSession(_ s: AuthSession?) {
        if let s, let data = try? JSONEncoder().encode(s) {
            Keychain.set(String(data: data, encoding: .utf8), for: "auth.session")
        } else {
            Keychain.set(nil, for: "auth.session")
        }
        withAnimation(.easeInOut(duration: 0.35)) { session = s }
    }

    /// Opens the app with no account at all. Everything works and stays on this
    /// device; Drive backup and Google Calendar sync need a Google account, and
    /// you can connect one later from Settings without losing anything.
    @MainActor
    func signInAsGuest() {
        lastError = nil
        setSession(AuthSession(method: .guest, name: "Guest", email: nil))
    }

    /// Signs out of the app completely (session, Apple and Google).
    @MainActor
    func signOutEverywhere() {
        signOutApple()
        if isGoogleSignedIn { signOutGoogle() }
        lastError = nil
        setSession(nil)
    }

    // MARK: Apple

    @MainActor
    func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            Keychain.set(cred.user, for: "apple.userID")
            // Apple only sends name/email the very first time — keep what we had otherwise.
            if let n = cred.fullName, let name = PersonNameComponentsFormatter().string(for: n), !name.isEmpty {
                Keychain.set(name, for: "apple.name")
            }
            if let e = cred.email { Keychain.set(e, for: "apple.email") }
            appleUserID = cred.user
            appleName = Keychain.get("apple.name")
            appleEmail = Keychain.get("apple.email")
            lastError = nil
            setSession(AuthSession(method: .apple,
                                   name: appleName ?? "Apple ID",
                                   email: appleEmail))
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            lastError = "Apple sign-in isn't available in this build yet. In Xcode: target → Signing & Capabilities → + Capability → Sign in with Apple (needs a paid Apple Developer team). Use Developer login meanwhile."
        }
    }

    @MainActor
    func signOutApple() {
        ["apple.userID", "apple.name", "apple.email"].forEach { Keychain.set(nil, for: $0) }
        appleUserID = nil; appleName = nil; appleEmail = nil
    }

    /// Re-checks that the Apple ID credential is still valid (user may have revoked it).
    @MainActor
    func refreshAppleState() {
        guard let id = appleUserID else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { state, _ in
            if state == .revoked || state == .notFound {
                Task { @MainActor in
                    let store = AccountStore.shared
                    store.signOutApple()
                    if store.session?.method == .apple { store.setSession(nil) }
                }
            }
        }
    }

    // MARK: Google (OAuth 2.0 + PKCE, no SDK needed)

    private var trimmedClientID: String { AppConfig.effectiveGoogleClientID }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    private var redirectScheme: String {
        trimmedClientID.split(separator: ".").reversed().joined(separator: ".")
    }

    /// Google sign-in. `asLogin` = this is the app login (creates the session);
    /// otherwise it just connects Google for Calendar/Drive sync.
    @MainActor
    @discardableResult
    func signInWithGoogle(using session: WebAuthenticationSession, asLogin: Bool = false) async -> Bool {
        lastError = nil
        guard AppConfig.isGoogleConfigured else {
            lastError = "Google sign-in isn't set up in this build yet — add the Google client ID in AppConfig (Models/Accounts.swift). Use Developer login meanwhile."
            return false
        }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)
        let redirect = "\(redirectScheme):/oauth2redirect"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: trimmedClientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: mainScopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        do {
            let callback = try await session.authenticate(using: comps.url!,
                                                          callbackURLScheme: redirectScheme,
                                                          preferredBrowserSession: .shared)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                lastError = "Google sign-in was cancelled or returned no code."
                return false
            }
            try await exchange(["code": code,
                                "code_verifier": verifier,
                                "redirect_uri": redirect,
                                "grant_type": "authorization_code"])
            googleEmail = try await fetchGoogleEmail()
            Keychain.set(googleEmail, for: "google.email")
            objectWillChange.send()
            if asLogin {
                setSession(AuthSession(method: .google, name: googleEmail ?? "Google account", email: googleEmail))
            }
            return true
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return false }
            lastError = "Google sign-in failed: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func signOutGoogle() {
        if let token = Keychain.get("google.refresh") ?? Keychain.get("google.access") {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        ["google.access", "google.refresh", "google.expiry", "google.email", "google.scope"].forEach { Keychain.set(nil, for: $0) }
        googleEmail = nil
        objectWillChange.send()
    }

    /// A valid access token, refreshed automatically when it has expired.
    @MainActor
    func googleAccessToken() async throws -> String {
        try await accessToken(prefix: "google")
    }

    /// The Colab account's token — a different Google account from the one
    /// above, when you've connected one.
    @MainActor
    func colabAccessToken() async throws -> String {
        try await accessToken(prefix: "colab")
    }

    @MainActor
    private func accessToken(prefix: String) async throws -> String {
        if let token = Keychain.get("\(prefix).access"),
           let exp = Keychain.get("\(prefix).expiry").flatMap(Double.init),
           Date().timeIntervalSince1970 < exp - 60 {
            return token
        }
        guard let refresh = Keychain.get("\(prefix).refresh") else { throw SyncError.notSignedIn }
        try await exchange(["refresh_token": refresh, "grant_type": "refresh_token"], prefix: prefix)
        guard let token = Keychain.get("\(prefix).access") else { throw SyncError.notSignedIn }
        return token
    }

    // MARK: The Colab connection

    /// Signs in a Google account purely to read its Colab notebooks. Google is
    /// asked to show the account chooser, so you can pick a university address
    /// even when you're already signed in to a personal one.
    @MainActor
    @discardableResult
    func connectColabAccount(using session: WebAuthenticationSession) async -> Bool {
        lastError = nil
        guard AppConfig.isGoogleConfigured else {
            lastError = "Google isn't set up in this build yet."
            return false
        }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)
        let redirect = "\(redirectScheme):/oauth2redirect"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: trimmedClientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: colabScopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            // Both, so Google always offers the chooser and always returns a
            // refresh token for this second account.
            .init(name: "prompt", value: "select_account consent"),
        ]
        do {
            let callback = try await session.authenticate(using: comps.url!,
                                                          callbackURLScheme: redirectScheme,
                                                          preferredBrowserSession: .shared)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                lastError = "Google sign-in was cancelled."
                return false
            }
            try await exchange(["code": code,
                                "code_verifier": verifier,
                                "redirect_uri": redirect,
                                "grant_type": "authorization_code"], prefix: "colab")
            let email = try await fetchEmail(prefix: "colab")
            Keychain.set(email, for: "colab.email")
            objectWillChange.send()
            return true
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return false }
            lastError = "Couldn't connect that account: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func disconnectColabAccount() {
        if let token = Keychain.get("colab.refresh") ?? Keychain.get("colab.access") {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        ["colab.access", "colab.refresh", "colab.expiry", "colab.email", "colab.scope"]
            .forEach { Keychain.set(nil, for: $0) }
        objectWillChange.send()
    }

    @MainActor
    private func exchange(_ params: [String: String], prefix: String = "google") async throws {
        var body = params
        body["client_id"] = trimmedClientID
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw SyncError.server(String(data: data, encoding: .utf8) ?? "token error")
        }
        Keychain.set(access, for: "\(prefix).access")
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        Keychain.set(String(Date().timeIntervalSince1970 + expiresIn), for: "\(prefix).expiry")
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, for: "\(prefix).refresh") }
        if let scope = json["scope"] as? String { Keychain.set(scope, for: "\(prefix).scope") }
    }

    @MainActor
    private func fetchGoogleEmail() async throws -> String? {
        try await fetchEmail(prefix: "google")
    }

    @MainActor
    private func fetchEmail(prefix: String) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        req.setValue("Bearer \(try await accessToken(prefix: prefix))", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["email"] as? String
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64URL
    }
}

enum SyncError: LocalizedError {
    case notSignedIn, noAccess, server(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .noAccess: return "Calendar access was not granted."
        case .server(let s): return s
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

// MARK: - Google Calendar REST client

enum GoogleCalendarClient {
    private static let base = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Creates or updates an all-day event. Returns the Google event id.
    @MainActor
    static func upsert(existingID: String?, title: String, notes: String, day: Date) async throws -> String {
        let token = try await AccountStore.shared.googleAccessToken()
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let payload: [String: Any] = [
            "summary": title,
            "description": notes,
            "start": ["date": dayFormat.string(from: start)],
            "end": ["date": dayFormat.string(from: end)],
        ]
        if let id = existingID {
            var req = URLRequest(url: URL(string: "\(base)/\(id)")!)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return id }
            if code != 404 && code != 410 { throw SyncError.server("Google Calendar returned \(code)") }
            // Deleted on Google's side — fall through and recreate.
        }
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SyncError.server(String(data: data, encoding: .utf8) ?? "Google Calendar error")
        }
        return id
    }

    @MainActor
    static func delete(id: String) async throws {
        let token = try await AccountStore.shared.googleAccessToken()
        var req = URLRequest(url: URL(string: "\(base)/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }
}
