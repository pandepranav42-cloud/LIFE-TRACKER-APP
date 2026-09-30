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

    enum CodingKeys: String, CodingKey {
        case id, name, full_name, description, default_branch, html_url, updated_at, size
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
            case 422: return "GitHub wouldn't accept that: \(message)"
            default: return "GitHub error \(code): \(message)"
            }
        case .badResponse:
            return "GitHub sent something unexpected."
        case .tooLarge(let name):
            return "“\(name)” is over 50 MB — GitHub's upload API won't take it."
        }
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
    static func expand(_ urls: [URL], into folder: String) -> [Upload] {
        var uploads: [Upload] = []
        let fm = FileManager.default
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))

        func add(_ url: URL, path: String) {
            let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
            let full = prefix.isEmpty ? path : "\(prefix)/\(path)"
            uploads.append(Upload(localURL: url, remotePath: full, byteCount: size))
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let root = url.lastPathComponent
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let child = enumerator?.nextObject() as? URL {
                    var childIsDir: ObjCBool = false
                    fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
                    if childIsDir.boolValue { continue }
                    let relative = child.path.replacingOccurrences(of: url.path + "/", with: "")
                    add(child, path: "\(root)/\(relative)")
                }
            } else {
                add(url, path: url.lastPathComponent)
            }
        }
        return uploads
    }

    /// Pushes every file, one commit each (that's what the Contents API does).
    /// Returns the files that failed, with the reason.
    @MainActor
    func push(_ uploads: [Upload], to repo: GitHubRepo, message: String) async -> [(String, String)] {
        guard !uploads.isEmpty else { return [] }
        isBusy = true
        progress = 0
        progressPercent = 0
        var failures: [(String, String)] = []
        let commit = message.trimmingCharacters(in: .whitespacesAndNewlines)

        for (index, item) in uploads.enumerated() {
            progressLabel = item.remotePath
            progressDetail = "file \(index + 1) of \(uploads.count)"
            progress = Double(index) / Double(uploads.count)

            if item.byteCount > Self.maxUploadBytes {
                failures.append((item.remotePath, "over 50 MB"))
                continue
            }
            guard let data = try? Data(contentsOf: item.localURL) else {
                failures.append((item.remotePath, "couldn't be read"))
                continue
            }
            let encoded = item.remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.remotePath
            let existing = try? await get("repos/\(repo.full_name)/contents/\(encoded)?ref=\(repo.branch)",
                                          as: GitHubEntry.self)
            var body: [String: Any] = [
                "message": commit.isEmpty ? "Add \((item.remotePath as NSString).lastPathComponent) from LifeTracker" : commit,
                "content": data.base64EncodedString(),
                "branch": repo.branch
            ]
            if let sha = existing?.sha { body["sha"] = sha }     // updates instead of failing

            do {
                var request = try self.request("repos/\(repo.full_name)/contents/\(encoded)", method: "PUT")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let slot = Double(index), count = Double(uploads.count)
                _ = try await upload(request, body: request.httpBody, file: nil) { fraction in
                    Task { @MainActor in
                        self.progress = min(1, (slot + fraction) / count)
                        self.progressPercent = Int((min(1, (slot + fraction) / count) * 100).rounded())
                    }
                }
            } catch {
                failures.append((item.remotePath, error.localizedDescription))
            }
        }

        progress = 1
        progressPercent = 100
        progressLabel = ""
        progressDetail = ""
        isBusy = false
        let done = uploads.count - failures.count
        status = failures.isEmpty
            ? "Pushed \(done) file\(done == 1 ? "" : "s") to \(repo.full_name)"
            : "Pushed \(done) of \(uploads.count) — \(failures.count) failed"
        lastError = failures.isEmpty ? nil : failures.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return failures
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
