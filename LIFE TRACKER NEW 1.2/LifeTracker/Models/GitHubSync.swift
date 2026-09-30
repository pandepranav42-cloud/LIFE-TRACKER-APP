import Foundation
import SwiftUI

// MARK: - GitHub, without the terminal
//
// Everything here talks to the GitHub REST API with a personal access token
// kept in the Keychain. No git, no clone, no commit commands: a file you drop
// becomes a commit through the Contents API, which is exactly what the web
// "Upload files" button does.
//
// Token scopes: `repo` covers reading, creating and pushing. Add
// `delete_repo` as well if you want the app to delete whole repositories.

struct GitHubUser: Codable, Equatable {
    let id: Int?
    let login: String
    let name: String?
    let avatar_url: String?
    let bio: String?
    let company: String?
    let location: String?
    let blog: String?
    let followers: Int?
    let following: Int?
    let public_repos: Int?
    let html_url: String?
    let created_at: String?

    var displayName: String { (name?.isEmpty == false) ? name! : login }

    /// The address GitHub itself uses when you commit from the web editor.
    /// It is always linked to the account, which is what decides whether a
    /// commit shows up on the contribution graph — a commit authored with an
    /// address GitHub can't match to you counts for nobody.
    var commitEmail: String {
        if let id { return "\(id)+\(login)@users.noreply.github.com" }
        return "\(login)@users.noreply.github.com"
    }
}

/// One square in the contribution graph.
struct ContributionDay: Identifiable, Equatable {
    let date: Date
    let count: Int
    var id: Date { date }
}

/// A year of green dots, already grouped into the columns GitHub draws.
struct ContributionYear: Equatable {
    var total: Int = 0
    /// Each inner array is one week, Sunday first.
    var weeks: [[ContributionDay]] = []

    var busiestDay: Int { weeks.flatMap { $0 }.map(\.count).max() ?? 0 }

    /// Days in a row up to today with at least one contribution.
    var currentStreak: Int {
        let days = weeks.flatMap { $0 }.filter { $0.date <= Date() }.sorted { $0.date > $1.date }
        var streak = 0
        for day in days {
            // Today not having a commit yet doesn't end yesterday's streak.
            if day.count == 0 && Calendar.current.isDateInToday(day.date) { continue }
            guard day.count > 0 else { break }
            streak += 1
        }
        return streak
    }
}

struct GitHubRepo: Codable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let full_name: String
    /// GitHub calls this "private", which is a Swift keyword — renamed here.
    let isPrivate: Bool
    let description: String?
    let default_branch: String?
    let html_url: String
    let updated_at: String?
    let size: Int?
    /// Commits in a fork never appear on the contribution graph.
    let fork: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, full_name, description, default_branch, html_url, updated_at, size, fork
        case isPrivate = "private"
    }

    var owner: String { full_name.components(separatedBy: "/").first ?? "" }
    var branch: String { default_branch ?? "main" }
}

/// One entry in a repository folder.
struct GitHubEntry: Codable, Identifiable, Equatable {
    let name: String
    let path: String
    let sha: String
    let size: Int?
    let type: String          // "file" | "dir"
    let html_url: String?
    let download_url: String?
    /// Only present when GitHub is asked for a single file.
    let content: String?
    let encoding: String?

    var id: String { path }
    var isDirectory: Bool { type == "dir" }

    /// The file's text, for the small ones LifeTracker edits in place.
    var decodedText: String? {
        guard let content, encoding == "base64" else { return nil }
        guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A text file being edited in the app, with the sha GitHub needs to accept
/// the change (nil when the file doesn't exist yet).
struct GitHubTextFile {
    var path: String
    var text: String
    var sha: String?
}

/// A published (or draft) release on a repository.
struct GitHubRelease: Codable, Identifiable, Equatable {
    let id: Int
    let tag_name: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let html_url: String
    let published_at: String?
    let created_at: String?
    let assets: [Asset]?

    struct Asset: Codable, Identifiable, Equatable {
        let id: Int
        let name: String
        let size: Int
        let download_count: Int?
        let browser_download_url: String
    }

    var title: String { (name?.isEmpty == false ? name! : tag_name) }
    var assetCount: Int { assets?.count ?? 0 }
}

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case badResponse
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Connect a GitHub token first."
        case .http(let code, let message):
            switch code {
            case 401: return "GitHub rejected the token (401). It may be expired or mistyped."
            case 403: return "GitHub refused (403). The token is probably missing a scope — \(message)"
            case 404: return "Not found (404). Either it doesn't exist or the token can't see it."
            case 409: return "That repository is empty or the branch doesn't exist yet (409)."
            case 422:
                // Push protection. GitHub's own wording ("Repository rule
                // violations found") says nothing about what to do, and the
                // failure gets pinned on the branch rather than on the file
                // that actually carries the key — so say it plainly.
                if Self.looksLikeSecretBlock(message) {
                    return "GitHub blocked this push: one of these files has an API key or token written into it. Take the key out of the file — keep it in Settings, or in a Secrets file git ignores — then push again. GitHub refuses the whole commit until it's gone, so nothing went up. (GitHub said: \(message))"
                }
                return "GitHub wouldn't accept that: \(message)"
            default: return "GitHub error \(code): \(message)"
            }
        case .badResponse:
            return "GitHub sent something unexpected."
        case .tooLarge(let name):
            return "“\(name)” is over 50 MB — GitHub's upload API won't take it."
        }
    }

    /// Whether a 422 is secret-scanning push protection rather than an
    /// ordinary validation complaint.
    static func looksLikeSecretBlock(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("secret") || lowered.contains("push protection")
            || lowered.contains("rule violation")
    }

    /// True when this error is push protection, wherever it surfaced.
    var isSecretBlock: Bool {
        if case .http(422, let message) = self { return Self.looksLikeSecretBlock(message) }
        return false
    }
}

final class GitHubSync: ObservableObject {
    static let shared = GitHubSync()

    @Published private(set) var user: GitHubUser?
    @Published private(set) var repos: [GitHubRepo] = []
    @Published private(set) var isBusy = false
    @Published var status: String = ""
    @Published var lastError: String?

    /// 0…1 while a batch of files is uploading.
    @Published var progress: Double = 0
    /// The same thing as a whole number, for the "43%" label.
    @Published var progressPercent: Int = 0
    @Published var progressLabel: String = ""
    /// "file 2 of 7", or the size being sent.
    @Published var progressDetail: String = ""

    /// Every step of the last push, with what GitHub answered. Shown under
    /// the push controls so "it said it worked" can always be checked against
    /// what actually happened.
    @Published private(set) var pushLog: [String] = []
    /// The commit the last push created, so you can open it on GitHub.
    @Published private(set) var lastCommitURL: URL?

    /// Files the last push refused because the repository already has them,
    /// byte for byte, at the same path. Git records nothing for a file that
    /// hasn't changed, so pushing one again is a commit that does nothing —
    /// which is what "it said Pushed and nothing happened" always was.
    @Published private(set) var duplicates: [String] = []
    /// Where those duplicates were headed, for the "try another folder" hint.
    @Published private(set) var duplicateFolder: String = ""
    /// Files in the last push that were already there, when others weren't.
    @Published private(set) var skippedAsUnchanged = 0
    /// Whether the last commit will show on the contribution graph, and why not.
    @Published private(set) var contributionNote: String?

    /// The last contribution year fetched, kept so Life AI can summarise your
    /// GitHub activity without making a GraphQL call of its own on every
    /// message. Filled in whenever the profile screen loads the green dots.
    @Published private(set) var contributionCache: ContributionYear?

    private static let tokenKey = "github.token"
    /// GitHub's Contents API tops out around 100 MB; keep a safe margin.
    static let maxUploadBytes = 50 * 1024 * 1024

    private init() {
        if isConnected { Task { @MainActor in await refresh() } }
    }

    // MARK: Token

    var token: String? {
        let value = Keychain.get(Self.tokenKey)
        return (value?.isEmpty ?? true) ? nil : value
    }
    var isConnected: Bool { token != nil }

    /// Stores the token and checks it by asking GitHub who it belongs to.
    @MainActor
    @discardableResult
    func connect(token raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        Keychain.set(trimmed, for: Self.tokenKey)
        lastError = nil
        do {
            user = try await get("user", as: GitHubUser.self)
            status = "Connected as @\(user?.login ?? "")"
            await loadRepos()
            return true
        } catch {
            Keychain.set(nil, for: Self.tokenKey)
            user = nil
            lastError = error.localizedDescription
            return false
        }
    }

    @MainActor
    func disconnect() {
        Keychain.set(nil, for: Self.tokenKey)
        user = nil
        repos = []
        status = ""
        lastError = nil
    }

    @MainActor
    func refresh() async {
        guard isConnected else { return }
        do {
            user = try await get("user", as: GitHubUser.self)
            await loadRepos()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Repos

    @MainActor
    func loadRepos() async {
        guard isConnected else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var all: [GitHubRepo] = []
            var page = 1
            while page <= 5 {
                let batch = try await get("user/repos?per_page=100&sort=updated&affiliation=owner,collaborator&page=\(page)",
                                          as: [GitHubRepo].self)
                all += batch
                if batch.count < 100 { break }
                page += 1
            }
            repos = all
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    @discardableResult
    func createRepo(name: String, description: String, isPrivate: Bool, addReadme: Bool) async -> GitHubRepo? {
        let clean = Self.slug(name)
        guard !clean.isEmpty else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let body: [String: Any] = ["name": clean,
                                       "description": description,
                                       "private": isPrivate,
                                       "auto_init": addReadme]
            let repo = try await send("user/repos", method: "POST", json: body, as: GitHubRepo.self)
            repos.insert(repo, at: 0)
            status = "Created \(repo.full_name)"
            lastError = nil
            return repo
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @MainActor
    func deleteRepo(_ repo: GitHubRepo) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await sendRaw("repos/\(repo.full_name)", method: "DELETE", body: nil)
            repos.removeAll { $0.id == repo.id }
            status = "Deleted \(repo.full_name)"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Browsing

    @MainActor
    func contents(of repo: GitHubRepo, path: String) async -> [GitHubEntry] {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        do {
            let entries = try await get("repos/\(repo.full_name)/contents/\(encoded)", as: [GitHubEntry].self)
            lastError = nil
            return entries.sorted {
                $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
            }
        } catch {
            // An empty repository answers 404/409 — not worth shouting about.
            if let github = error as? GitHubError, case .http(let code, _) = github,
               code == 404 || code == 409 {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
            return []
        }
    }

    @MainActor
    func delete(_ entry: GitHubEntry, in repo: GitHubRepo, message: String) async -> Bool {
        let encoded = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
        do {
            let body: [String: Any] = ["message": message.isEmpty ? "Delete \(entry.name)" : message,
                                       "sha": entry.sha,
                                       "branch": repo.branch]
            _ = try await sendRaw("repos/\(repo.full_name)/contents/\(encoded)", method: "DELETE", body: body)
            status = "Deleted \(entry.path)"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Profile

    /// The green dots. The REST API doesn't expose contributions at all, so
    /// this is the one GraphQL call in the app. Needs `read:user` on the token
    /// (the `user` scope includes it).
    @MainActor
    func contributions(for login: String) async -> ContributionYear {
        guard let token, !login.isEmpty else { return ContributionYear() }
        let query = """
        query($login:String!) {
          user(login:$login) {
            contributionsCollection {
              contributionCalendar {
                totalContributions
                weeks { contributionDays { date contributionCount } }
              }
            }
          }
        }
        """
        guard let url = URL(string: "https://api.github.com/graphql") else { return ContributionYear() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LifeTracker", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["login": login]
        ])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ContributionYear()
            }
            if let errors = root["errors"] as? [[String: Any]], let first = errors.first,
               let text = first["message"] as? String {
                lastError = "Contributions: \(text) — the token probably needs the read:user scope."
                return ContributionYear()
            }
            guard let calendar = (((root["data"] as? [String: Any])?["user"] as? [String: Any])?["contributionsCollection"] as? [String: Any])?["contributionCalendar"] as? [String: Any] else {
                return ContributionYear()
            }
            var year = ContributionYear()
            year.total = (calendar["totalContributions"] as? Int) ?? 0

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)

            for week in (calendar["weeks"] as? [[String: Any]]) ?? [] {
                var days: [ContributionDay] = []
                for day in (week["contributionDays"] as? [[String: Any]]) ?? [] {
                    guard let text = day["date"] as? String, let date = formatter.date(from: text) else { continue }
                    days.append(ContributionDay(date: date, count: (day["contributionCount"] as? Int) ?? 0))
                }
                if !days.isEmpty { year.weeks.append(days) }
            }
            contributionCache = year
            return year
        } catch {
            lastError = error.localizedDescription
            return ContributionYear()
        }
    }

    /// Updates the bits of the profile GitHub lets an API change. The avatar is
    /// deliberately not here — GitHub has no endpoint for it.
    @MainActor
    @discardableResult
    func updateProfile(name: String, bio: String, company: String, location: String, blog: String) async -> Bool {
        do {
            let body: [String: Any] = ["name": name, "bio": bio, "company": company,
                                       "location": location, "blog": blog]
            user = try await send("user", method: "PATCH", json: body, as: GitHubUser.self)
            status = "Profile updated"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Text files (README and friends)

    /// Loads a small text file for editing. Returns an empty one with no sha
    /// when the file isn't there yet, so the editor can create it.
    @MainActor
    func readTextFile(at path: String, in repo: GitHubRepo) async -> GitHubTextFile {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        do {
            let entry = try await get("repos/\(repo.full_name)/contents/\(encoded)?ref=\(repo.branch)",
                                      as: GitHubEntry.self)
            lastError = nil
            return GitHubTextFile(path: entry.path, text: entry.decodedText ?? "", sha: entry.sha)
        } catch {
            // 404 just means "not created yet" — that's a normal starting point.
            if let github = error as? GitHubError, case .http(let code, _) = github,
               code == 404 || code == 409 {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
            return GitHubTextFile(path: path, text: "", sha: nil)
        }
    }

    /// Commits a text file — creating it, or updating it when a sha is given.
    @MainActor
    func saveTextFile(_ file: GitHubTextFile, in repo: GitHubRepo, message: String) async -> Bool {
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        var body: [String: Any] = [
            "message": message.isEmpty ? "Update \((file.path as NSString).lastPathComponent)" : message,
            "content": Data(file.text.utf8).base64EncodedString(),
            "branch": repo.branch
        ]
        if let sha = file.sha { body["sha"] = sha }
        do {
            _ = try await sendRaw("repos/\(repo.full_name)/contents/\(encoded)", method: "PUT", body: body)
            status = "Saved \(file.path)"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Downloading

    /// Pulls a file out of a repo into a temporary file, reporting progress as
    /// it goes. Works for private repos too, because it asks the API for the
    /// raw bytes rather than hitting the public download URL.
    @MainActor
    func download(_ entry: GitHubEntry, in repo: GitHubRepo,
                  onProgress: @escaping (Double) -> Void) async throws -> URL {
        let encoded = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
        var request = try self.request("repos/\(repo.full_name)/contents/\(encoded)?ref=\(repo.branch)", method: "GET")
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        return try await fetchFile(request, named: entry.name, onProgress: onProgress)
    }

    /// Same, for a file attached to a release.
    /// Release assets go through the API rather than `browser_download_url`:
    /// that public URL redirects to storage with its own signed auth, which
    /// rejects our token — and 404s for a private repo.
    @MainActor
    func download(asset: GitHubRelease.Asset, in repo: GitHubRepo,
                  onProgress: @escaping (Double) -> Void) async throws -> URL {
        var request = try self.request("repos/\(repo.full_name)/releases/assets/\(asset.id)", method: "GET")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await fetchFile(request, named: asset.name, onProgress: onProgress)
    }

    /// Downloads to a file with a real progress signal. Reading
    /// `URLSession.bytes` a byte at a time would crawl on a 2 GB build, so
    /// this drives a download task and watches its Progress object.
    nonisolated private func fetchFile(_ request: URLRequest, named name: String,
                                       onProgress: @escaping (Double) -> Void) async throws -> URL {
        final class Box: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var finished = false
            var last: Double = -1
        }
        let box = Box()

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { location, response, error in
                guard !box.finished else { return }
                box.finished = true
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code), let location else {
                    continuation.resume(throwing: GitHubError.http(code, ""))
                    return
                }
                // The temporary file is deleted the moment this handler
                // returns, so it has to be moved now, not later.
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GitHubDownloads/\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(name.isEmpty ? "download" : name)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let fraction = progress.fractionCompleted
                // A tick per percent is plenty; otherwise the UI is flooded.
                guard fraction >= box.last + 0.01 || fraction >= 1 else { return }
                box.last = fraction
                onProgress(fraction)
            }
            task.resume()
        }
    }

    // MARK: Releases
    //
    // A release is how you hand someone a finished build: a tag, some notes,
    // and the actual files (.zip, .dmg, .ipa) attached for download. Assets go
    // to uploads.github.com rather than api.github.com, which is why they
    // don't run through `sendRaw`.

    @MainActor
    func releases(for repo: GitHubRepo) async -> [GitHubRelease] {
        do {
            let list = try await get("repos/\(repo.full_name)/releases?per_page=50", as: [GitHubRelease].self)
            lastError = nil
            return list
        } catch {
            if let github = error as? GitHubError, case .http(404, _) = github {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
            return []
        }
    }

    /// Creates the release, then attaches every file you staged for it.
    /// Returns the release, or nil if GitHub refused to create it.
    @MainActor
    func createRelease(in repo: GitHubRepo,
                       tag: String,
                       title: String,
                       notes: String,
                       isDraft: Bool,
                       isPrerelease: Bool,
                       assets: [Upload]) async -> GitHubRelease? {
        isBusy = true
        defer { isBusy = false }
        progress = 0
        progressPercent = 0

        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTag.isEmpty else {
            lastError = "A release needs a tag, like v1.0."
            return nil
        }

        var release: GitHubRelease
        do {
            let body: [String: Any] = ["tag_name": cleanTag,
                                       "name": title.isEmpty ? cleanTag : title,
                                       "body": notes,
                                       "draft": isDraft,
                                       "prerelease": isPrerelease,
                                       "target_commitish": repo.branch]
            release = try await send("repos/\(repo.full_name)/releases", method: "POST",
                                     json: body, as: GitHubRelease.self)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        var failed: [String] = []
        for (index, asset) in assets.enumerated() {
            progressLabel = asset.remotePath
            progress = Double(index) / Double(max(assets.count, 1))
            let name = (asset.remotePath as NSString).lastPathComponent
            progressDetail = "file \(index + 1) of \(assets.count) · \(ByteCountFormatter.string(fromByteCount: Int64(asset.byteCount), countStyle: .file))"
            do {
                try await upload(asset: asset, named: name, to: release.id, in: repo,
                                 slot: Double(index), total: Double(max(assets.count, 1)))
            } catch {
                failed.append("\(name): \(error.localizedDescription)")
            }
        }
        progress = 1
        progressPercent = 100
        progressLabel = ""
        progressDetail = ""

        status = failed.isEmpty
            ? "Released \(cleanTag)\(assets.isEmpty ? "" : " with \(assets.count) file\(assets.count == 1 ? "" : "s")")"
            : "Released \(cleanTag), but \(failed.count) file\(failed.count == 1 ? "" : "s") didn't attach"
        lastError = failed.isEmpty ? nil : failed.joined(separator: "\n")

        // Re-read it so the asset list is accurate.
        let refreshed = try? await get("repos/\(repo.full_name)/releases/\(release.id)", as: GitHubRelease.self)
        if let refreshed { release = refreshed }
        return release
    }

    @MainActor
    func deleteRelease(_ release: GitHubRelease, in repo: GitHubRepo) async -> Bool {
        do {
            _ = try await sendRaw("repos/\(repo.full_name)/releases/\(release.id)", method: "DELETE", body: nil)
            status = "Deleted release \(release.tag_name)"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func upload(asset: Upload, named name: String, to releaseID: Int, in repo: GitHubRepo,
                        slot: Double, total: Double) async throws {
        guard let token else { throw GitHubError.noToken }
        // The name is a query *value*, so `&`, `+`, `=` and `?` have to go too
        // — .urlQueryAllowed leaves them alone and GitHub then answers 422.
        let safe = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
        let encoded = name.addingPercentEncoding(withAllowedCharacters: safe) ?? name
        guard let url = URL(string: "https://uploads.github.com/repos/\(repo.full_name)/releases/\(releaseID)/assets?name=\(encoded)") else {
            throw GitHubError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LifeTracker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // Streamed from disk, so a 300 MB build doesn't sit in memory. Release
        // assets are allowed up to 2 GB, unlike the 50 MB file API.
        _ = try await upload(request, body: nil, file: asset.localURL) { fraction in
            Task { @MainActor in
                self.progress = min(1, (slot + fraction) / total)
                self.progressPercent = Int((min(1, (slot + fraction) / total) * 100).rounded())
            }
        }
    }

    // MARK: Uploading

    struct Upload: Identifiable {
        let id = UUID()
        let localURL: URL
        /// Where it lands in the repo, e.g. "notes/week-3/slides.pdf".
        var remotePath: String
        let byteCount: Int
    }

    /// Expands whatever you dropped into a flat list of files. A folder keeps
    /// its shape: dropping `Sem5/` puts everything under `Sem5/…` in the repo.
    ///
    /// Every path is standardised first. A folder dragged out of Finder often
    /// arrives with a trailing slash, and the old code built the child's
    /// relative path by cutting `url.path + "/"` off the front — which matches
    /// nothing when the parent already ends in one. Every file in that folder
    /// then kept its whole absolute path and landed in the repo as
    /// `Sem5/Users/you/Desktop/Sem5/notes.pdf`. Trimming the components
    /// instead can't go wrong that way.
    static func expand(_ urls: [URL], into folder: String) -> [Upload] {
        var uploads: [Upload] = []
        let fm = FileManager.default
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))

        func add(_ url: URL, path: String) {
            // `resourceValues` sees a file the old `attributesOfItem` call
            // can't — a document still syncing down from iCloud, say.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                ?? ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int)
                ?? 0
            let full = prefix.isEmpty ? path : "\(prefix)/\(path)"
            uploads.append(Upload(localURL: url, remotePath: cleanPath(full), byteCount: size))
        }

        for raw in urls {
            let url = raw.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let root = url.lastPathComponent
                // Reading a folder's contents is a second permission from the
                // one granted for the folder itself on recent macOS.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let base = url.pathComponents
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let child = enumerator?.nextObject() as? URL {
                    let child = child.standardizedFileURL
                    let isRegular = (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    guard isRegular else { continue }
                    let relative = child.pathComponents.dropFirst(base.count).joined(separator: "/")
                    guard !relative.isEmpty else { continue }
                    add(child, path: "\(root)/\(relative)")
                }
            } else {
                add(url, path: url.lastPathComponent)
            }
        }
        return uploads
    }

    /// Copies one staged file into the app's own temporary folder, and says
    /// what went wrong when it can't.
    ///
    /// `copyItem` carries a file's ACLs, extended attributes and quarantine
    /// flag across with it, and on recent macOS that is enough to fail on a
    /// file the app is perfectly able to *read* — a download still carrying
    /// its com.apple.quarantine tag, anything tagged by another app. Reading
    /// the bytes and writing fresh ones asks for nothing but read permission,
    /// which is exactly what the Colab path has always done, and is why
    /// notebooks kept pushing when dropped files stopped.
    static func stageCopy(of item: Upload, into root: URL) throws -> Upload {
        let fm = FileManager.default
        let destination = root.appendingPathComponent(item.remotePath)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }

        let scoped = item.localURL.startAccessingSecurityScopedResource()
        defer { if scoped { item.localURL.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: item.localURL, options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
            return Upload(localURL: destination, remotePath: item.remotePath, byteCount: data.count)
        } catch {
            // A file too big to map comfortably still copies.
            try fm.copyItem(at: item.localURL, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? item.byteCount
            return Upload(localURL: destination, remotePath: item.remotePath, byteCount: size)
        }
    }

    /// A fresh folder under the app's own temporary directory — somewhere it
    /// can always write, whatever macOS thinks of the originals.
    static func newStagingFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubStaging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Pushes everything you staged as ONE commit.
    ///
    /// This used to drive the Contents API, a file at a time. That API writes
    /// onto an existing branch and answers 409 when there isn't one — which is
    /// every push into a repository that has no commits yet, and the reason a
    /// fresh repo used to be a dead end.
    ///
    /// So it goes through git's own objects instead, exactly as `git push`
    /// does: a blob per file, one tree on top of whatever the branch already
    /// points at, one commit, then move the branch. If the branch doesn't
    /// exist the commit simply has no parent and the branch is created
    /// pointing at it. Nothing special is needed for an empty repository,
    /// folders with spaces, or files that already exist.
    ///
    /// Returns the files that failed, with the reason.
    @MainActor
    func push(_ uploads: [Upload], to repo: GitHubRepo, message: String) async -> [(String, String)] {
        guard !uploads.isEmpty else { return [] }
        isBusy = true
        progress = 0
        progressPercent = 0

        pushLog = []
        lastCommitURL = nil
        duplicates = []
        duplicateFolder = ""
        skippedAsUnchanged = 0
        contributionNote = nil
        note("repo \(repo.full_name) · branch \(repo.branch)")

        var failures: [(String, String)] = []
        let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = typed.isEmpty ? Self.defaultMessage(for: uploads) : typed

        // Where the branch is now — nil when the repository has no commits.
        let head: (commit: String, tree: String)?
        do {
            head = try await headOfBranch(repo)
            note(head == nil
                 ? "branch has no commits yet — it will be created"
                 : "branch is at \(head!.commit.prefix(7))")
        } catch {
            note("couldn't read the branch: \(error.localizedDescription)")
            failures.append((repo.branch, "couldn't read the branch: \(error.localizedDescription)"))
            finishPush(pushed: 0, of: uploads.count, repo: repo, failures: failures)
            return failures
        }

        // A blob per file. The steps are weighted so the meter still reaches
        // the end when the commit itself is made.
        var entries: [(path: String, sha: String)] = []
        let steps = Double(uploads.count + 1)

        for (index, item) in uploads.enumerated() {
            progressLabel = item.remotePath
            progressDetail = "file \(index + 1) of \(uploads.count)"
            setProgress(Double(index) / steps)

            if item.byteCount > Self.maxUploadBytes {
                failures.append((item.remotePath, "over 50 MB"))
                continue
            }
            guard let data = try? Data(contentsOf: item.localURL, options: .mappedIfSafe) else {
                failures.append((item.remotePath, "couldn't be read"))
                continue
            }
            do {
                let slot = Double(index)
                let sha = try await makeBlob(repo, data: data) { fraction in
                    Task { @MainActor in self.setProgress((slot + fraction) / steps) }
                }
                entries.append((Self.cleanPath(item.remotePath), sha))
                note("blob \(Self.cleanPath(item.remotePath)) → \(sha.prefix(7))")
            } catch {
                note("blob \(item.remotePath) FAILED: \(error.localizedDescription)")
                failures.append((item.remotePath, error.localizedDescription))
            }
        }

        guard !entries.isEmpty else {
            finishPush(pushed: 0, of: uploads.count, repo: repo, failures: failures)
            return failures
        }

        // What the branch already holds at these paths. A git blob's sha is a
        // hash of its bytes, so a file whose sha matches the one already there
        // is the same file — putting it in the commit changes nothing.
        let alreadyThere = await existingBlobs(repo, tree: head?.tree)
        let unchanged = entries.filter { alreadyThere[$0.path] == $0.sha }
        entries = entries.filter { alreadyThere[$0.path] != $0.sha }
        skippedAsUnchanged = unchanged.count
        if !unchanged.isEmpty {
            note("already in the repo, unchanged: \(unchanged.count) file\(unchanged.count == 1 ? "" : "s")")
        }

        // Every single one is already there. Making the commit would move the
        // branch onto a tree identical to the one it is on: GitHub accepts it,
        // the repository looks untouched, and nothing explains why. Say so
        // instead, and let you rename or choose another folder.
        guard !entries.isEmpty else {
            duplicates = unchanged.map(\.path)
            duplicateFolder = (unchanged.first?.path as NSString?)?.deletingLastPathComponent ?? ""
            note("nothing to push — every file is already in the repo, unchanged")
            progress = 1
            progressPercent = 100
            progressLabel = ""
            progressDetail = ""
            isBusy = false
            status = unchanged.count == 1
                ? "That file is already in \(repo.name) — nothing to push"
                : "All \(unchanged.count) files are already in \(repo.name) — nothing to push"
            lastError = nil
            // Not a failure: nothing broke. The view reads `duplicates`.
            return []
        }

        progressLabel = "Making the commit…"
        progressDetail = ""
        setProgress(Double(uploads.count) / steps)

        do {
            let tree = try await makeTree(repo, base: head?.tree, entries: entries)
            note("tree → \(tree.prefix(7))")
            let commit = try await makeCommit(repo, message: commitMessage, tree: tree, parent: head?.commit)
            note("commit → \(commit.prefix(7))")
            try await moveBranch(repo, to: commit, branchExists: head != nil)
            note(head == nil ? "branch created" : "branch moved")

            // Don't take GitHub's word for it — read the branch back. A push
            // that says it worked has to be a push you can go and look at.
            let after = try? await headOfBranch(repo)
            if after?.commit == commit {
                note("verified: branch now at \(commit.prefix(7))")
                lastCommitURL = URL(string: "\(repo.html_url)/commit/\(commit)")
                let counts = Self.contributionNote(for: repo, user: user)
                contributionNote = counts
                note(counts)
            } else {
                note("NOT verified — branch is at \(after?.commit.prefix(7) ?? "unknown")")
                failures.append((repo.branch,
                                 "GitHub accepted the commit but the branch didn't move to it. Open the ⋯ details below and send me that list."))
                finishPush(pushed: 0, of: uploads.count, repo: repo, failures: failures)
                return failures
            }
        } catch {
            note("commit FAILED: \(error.localizedDescription)")
            // Push protection rejects the ref update, not the file, so the
            // message belongs to the push as a whole — repeating it once per
            // file just buries it.
            if let github = error as? GitHubError, github.isSecretBlock {
                failures.append((repo.branch, error.localizedDescription))
            } else {
                // The commit is all-or-nothing, so every file in it failed.
                for entry in entries { failures.append((entry.path, error.localizedDescription)) }
            }
            finishPush(pushed: 0, of: uploads.count, repo: repo, failures: failures)
            return failures
        }

        finishPush(pushed: entries.count, of: uploads.count, repo: repo, failures: failures)
        return failures
    }

    @MainActor
    private func note(_ line: String) {
        pushLog.append(line)
    }

    private func setProgress(_ value: Double) {
        // Upload callbacks can land after the push has finished; ignore them
        // rather than leaving the bar stuck at 60% with nothing running.
        guard isBusy else { return }
        let clamped = min(1, max(0, value))
        progress = clamped
        progressPercent = Int((clamped * 100).rounded())
    }

    private func finishPush(pushed: Int, of total: Int, repo: GitHubRepo, failures: [(String, String)]) {
        progress = 1
        progressPercent = 100
        progressLabel = ""
        progressDetail = ""
        isBusy = false
        // The count is what actually changed, not how many files were queued.
        // "Pushed 65 files" next to a commit touching four is the reason a
        // push that worked looked like a push that did nothing.
        let alsoSkipped = skippedAsUnchanged > 0
            ? " · \(skippedAsUnchanged) already up to date"
            : ""
        if pushed == 0 {
            status = "Nothing was pushed"
        } else if failures.isEmpty {
            status = "Pushed \(pushed) changed file\(pushed == 1 ? "" : "s") to \(repo.full_name)\(alsoSkipped)"
        } else {
            status = "Pushed \(pushed) of \(total) — \(failures.count) failed\(alsoSkipped)"
        }
        lastError = failures.isEmpty ? nil : failures.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private static func defaultMessage(for uploads: [Upload]) -> String {
        if uploads.count == 1 {
            return "Add \((uploads[0].remotePath as NSString).lastPathComponent) from LifeTracker"
        }
        return "Add \(uploads.count) files from LifeTracker"
    }

    /// git wants a clean relative path: no leading slash, no doubled slashes.
    static func cleanPath(_ raw: String) -> String {
        var path = raw
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    // MARK: The git objects behind a push

    /// The commit a branch points at, and its tree — or nil when the branch
    /// doesn't exist yet, which is what an empty repository looks like.
    private func headOfBranch(_ repo: GitHubRepo) async throws -> (commit: String, tree: String)? {
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        struct Commit: Decodable { struct Tree: Decodable { let sha: String }; let tree: Tree }
        let branch = repo.branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo.branch

        let ref: Ref
        do {
            ref = try await get("repos/\(repo.full_name)/git/ref/heads/\(branch)", as: Ref.self)
        } catch let error as GitHubError {
            // Only a real "it isn't there" means the branch is missing. A
            // timeout or a 500 must not be read as "this repo is empty" —
            // that would build a commit with no parent and try to start the
            // branch over.
            if case .http(let code, _) = error, code == 404 || code == 409 { return nil }
            throw error
        }
        let commit = try await get("repos/\(repo.full_name)/git/commits/\(ref.object.sha)", as: Commit.self)
        return (ref.object.sha, commit.tree.sha)
    }

    /// Every file the branch already has, as path → blob sha, read in one
    /// call. An empty repository (no tree yet) simply has none.
    ///
    /// Main-actor isolated, like `push` itself, because it writes to the push
    /// log. The network call inside simply suspends, so nothing is blocked.
    @MainActor
    private func existingBlobs(_ repo: GitHubRepo, tree: String?) async -> [String: String] {
        guard let tree else { return [:] }
        struct Tree: Decodable {
            struct Entry: Decodable { let path: String; let type: String; let sha: String }
            let tree: [Entry]
            let truncated: Bool?
        }
        do {
            let full = try await get("repos/\(repo.full_name)/git/trees/\(tree)?recursive=1", as: Tree.self)
            if full.truncated == true {
                // A repository big enough to truncate the listing: better to
                // let the push through than to call a file unchanged wrongly.
                note("repo too large to list in one go — duplicate check skipped")
                return [:]
            }
            var map: [String: String] = [:]
            for entry in full.tree where entry.type == "blob" { map[entry.path] = entry.sha }
            return map
        } catch {
            note("couldn't read the current tree (\(error.localizedDescription)) — duplicate check skipped")
            return [:]
        }
    }

    /// Whether a commit on this repository will show on your contribution
    /// graph, and what is stopping it when it won't.
    ///
    /// GitHub's rules: the commit's author email has to belong to your
    /// account, the commit has to be on the repository's default branch (or
    /// gh-pages), and the repository must not be a fork. The app always
    /// commits to `default_branch` and always authors with the account's own
    /// noreply address, so the two it can't control are the fork case and, for
    /// a private repository, the profile setting that hides private work.
    static func contributionNote(for repo: GitHubRepo, user: GitHubUser?) -> String {
        if repo.fork == true {
            return "This is a fork — GitHub never counts commits in a fork towards your contribution graph."
        }
        let who = user.map { "as \($0.commitEmail)" } ?? "as your account"
        if repo.isPrivate {
            return "Counted \(who) on \(repo.branch). This repository is private, so it only shows on your graph with “Include private contributions on my profile” switched on in GitHub → Settings → Profile."
        }
        return "Counted \(who) on \(repo.branch) — it will show on your contribution graph."
    }

    /// One file's bytes, stored as a git blob. Reports upload progress so the
    /// meter still moves for a big file.
    private func makeBlob(_ repo: GitHubRepo, data: Data,
                          onProgress: @escaping (Double) -> Void) async throws -> String {
        struct ShaOnly: Decodable { let sha: String }
        var request = try self.request("repos/\(repo.full_name)/git/blobs", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The body is handed to the upload task separately, so the request
        // must not hold a second copy of it — a big file is already 50 MB of
        // bytes plus 67 MB of base64.
        let payload = try JSONSerialization.data(
            withJSONObject: ["content": data.base64EncodedString(), "encoding": "base64"])
        request.httpBody = nil
        let reply = try await upload(request, body: payload, file: nil, onProgress: onProgress)
        guard let sha = try? JSONDecoder().decode(ShaOnly.self, from: reply).sha else {
            throw GitHubError.badResponse
        }
        return sha
    }

    /// The new tree. `base_tree` carries everything already in the repository
    /// forward, so a push adds and replaces rather than wiping the branch.
    private func makeTree(_ repo: GitHubRepo, base: String?,
                          entries: [(path: String, sha: String)]) async throws -> String {
        struct ShaOnly: Decodable { let sha: String }
        var body: [String: Any] = [
            "tree": entries.map { ["path": $0.path, "mode": "100644", "type": "blob", "sha": $0.sha] }
        ]
        if let base { body["base_tree"] = base }
        return try await send("repos/\(repo.full_name)/git/trees", method: "POST",
                              json: body, as: ShaOnly.self).sha
    }

    private func makeCommit(_ repo: GitHubRepo, message: String,
                            tree: String, parent: String?) async throws -> String {
        struct ShaOnly: Decodable { let sha: String }
        // Built in steps: an empty array literal inside a [String: Any] literal
        // has no type to infer from.
        let parents: [String] = parent.map { [$0] } ?? []
        var body: [String: Any] = ["message": message, "tree": tree]
        body["parents"] = parents

        // Say who wrote it, explicitly. Left out, the commit is authored with
        // whatever address the token resolves to — and if that address isn't
        // verified on the account, GitHub counts the commit for nobody and it
        // never appears on the contribution graph. The account's own noreply
        // address always matches.
        if let me = await currentUser() {
            let who: [String: Any] = ["name": me.displayName,
                                      "email": me.commitEmail,
                                      "date": Self.commitStamp()]
            body["author"] = who
            body["committer"] = who
        }
        return try await send("repos/\(repo.full_name)/git/commits", method: "POST",
                              json: body, as: ShaOnly.self).sha
    }

    /// The commit's author date, in *this device's* timezone.
    ///
    /// `ISO8601DateFormatter()` on its own writes UTC — "…T19:11:00Z". GitHub
    /// draws a contribution square on the date the commit claims in its own
    /// offset, so a UTC stamp puts anything pushed between midnight and 5:30am
    /// in India onto the *previous* day's square. Writing "+05:30" instead
    /// puts it where you actually did the work.
    static func commitStamp(_ date: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// Who is signed in, loading it if the app hasn't yet.
    @MainActor
    private func currentUser() async -> GitHubUser? {
        if let user { return user }
        await refresh()
        return user
    }

    /// Points the branch at the new commit, creating the branch when the
    /// repository didn't have one.
    private func moveBranch(_ repo: GitHubRepo, to sha: String, branchExists: Bool) async throws {
        if branchExists {
            let branch = repo.branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo.branch
            _ = try await sendRaw("repos/\(repo.full_name)/git/refs/heads/\(branch)",
                                  method: "PATCH", body: ["sha": sha])
        } else {
            _ = try await sendRaw("repos/\(repo.full_name)/git/refs", method: "POST",
                                  body: ["ref": "refs/heads/\(repo.branch)", "sha": sha])
        }
    }

    // MARK: REST plumbing

    private func request(_ path: String, method: String) throws -> URLRequest {
        guard let token else { throw GitHubError.noToken }
        guard let url = URL(string: "https://api.github.com/" + path) else { throw GitHubError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LifeTracker", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// An upload that reports how far along it is. `URLSession`'s async
    /// `upload(for:from:)` gives no progress at all, so this drives a real
    /// upload task and watches its Progress object.
    nonisolated private func upload(_ request: URLRequest,
                                    body: Data?,
                                    file: URL?,
                                    onProgress: @escaping (Double) -> Void) async throws -> Data {
        final class Box: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var finished = false
            var last: Double = -1
        }
        let box = Box()

        return try await withCheckedThrowingContinuation { continuation in
            let finish: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                guard !box.finished else { return }
                box.finished = true
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let payload = data ?? Data()
                guard (200..<300).contains(code) else {
                    continuation.resume(throwing: GitHubError.http(code, Self.message(from: payload)))
                    return
                }
                continuation.resume(returning: payload)
            }

            let task: URLSessionUploadTask
            if let file {
                task = URLSession.shared.uploadTask(with: request, fromFile: file, completionHandler: finish)
            } else {
                task = URLSession.shared.uploadTask(with: request, from: body ?? Data(), completionHandler: finish)
            }
            box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let fraction = progress.fractionCompleted
                guard fraction >= box.last + 0.01 || fraction >= 1 else { return }
                box.last = fraction
                onProgress(fraction)
            }
            task.resume()
        }
    }

    @discardableResult
    private func sendRaw(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        var request = try self.request(path, method: method)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw GitHubError.http(code, Self.message(from: data))
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await sendRaw(path, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.badResponse
        }
    }

    private func send<T: Decodable>(_ path: String, method: String, json: [String: Any], as type: T.Type) async throws -> T {
        let data = try await sendRaw(path, method: method, body: json)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.badResponse
        }
    }

    private static func message(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let main = (object["message"] as? String) ?? ""
        if let errors = object["errors"] as? [[String: Any]] {
            let detail: [String] = errors.compactMap { item in
                if let text = item["message"] as? String { return text }
                return item["field"] as? String
            }
            if !detail.isEmpty { return "\(main) (\(detail.joined(separator: ", ")))" }
        }
        return main
    }

    /// GitHub repo names allow letters, digits, dot, dash and underscore.
    static func slug(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let replaced = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return String(String.UnicodeScalarView(replaced.unicodeScalars.filter { allowed.contains($0) }))
    }
}
