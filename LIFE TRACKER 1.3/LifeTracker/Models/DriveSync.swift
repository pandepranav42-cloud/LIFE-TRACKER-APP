import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Backs up files you add in LifeTracker to Google Drive, inside a
/// "LifeTracker" folder:
///
///   LifeTracker/Study/<Subject>/…   — study materials (PDF, PPT, Word…)
///   LifeTracker/Mood Board/…        — mood-board pictures
///   LifeTracker/Covers/…            — Study cover image
///   LifeTracker/Timetable/…         — uploaded timetable image
///
/// Uses the `drive.file` scope, so the app can only see files it created —
/// never the rest of your Drive. When you delete a file in LifeTracker you're
/// asked whether the Drive copy should go too; if you say yes it's moved to
/// Drive's Bin, exactly as if you'd deleted it in Drive itself (recoverable
/// there for 30 days).
final class DriveSync: ObservableObject {
    static let shared = DriveSync()

    @AppStorage("sync.drive.enabled") var enabled: Bool = true { willSet { objectWillChange.send() } }

    @Published private(set) var status: String = ""
    @Published private(set) var isUploading = false
    @Published private(set) var pendingUploads = 0

    /// Cache of Drive folder ids by path ("LifeTracker/Study/Maths").
    private var folderCache: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "drive.folders") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "drive.folders") }
    }

    private init() {}

    /// True when uploads will actually happen.
    var isActive: Bool {
        enabled && AccountStore.shared.isGoogleSignedIn && AccountStore.shared.hasDriveScope
    }

    // MARK: Public hooks

    @MainActor
    func backup(_ material: StudyMaterial) async {
        guard isActive, material.driveFileID == nil else { return }
        let subject = material.subject?.name ?? "Unsorted"
        let name = material.fileExtension.isEmpty ? material.fileName : "\(material.fileName).\(material.fileExtension)"
        if let id = await upload(material.data, name: name, ext: material.fileExtension,
                                 folder: ["LifeTracker", "Study", subject]) {
            material.driveFileID = id
        }
    }

    @MainActor
    func backup(_ image: MoodBoardImage) async {
        guard isActive, image.driveFileID == nil else { return }
        let stamp = Self.stamp.string(from: image.addedAt)
        let folder = image.isCover ? "Covers" : "Mood Board"
        if let id = await upload(image.data, name: "\(folder) \(stamp).\(Self.imageExtension(image.data))",
                                 ext: Self.imageExtension(image.data), folder: ["LifeTracker", folder]) {
            image.driveFileID = id
        }
    }

    @MainActor
    func backup(_ asset: TimetableImageAsset) async {
        guard isActive, asset.driveFileID == nil else { return }
        let ext = Self.imageExtension(asset.imageData)
        let stamp = Self.stamp.string(from: .now)
        if let id = await upload(asset.imageData, name: "Timetable \(stamp).\(ext)", ext: ext,
                                 folder: ["LifeTracker", "Timetable"]) {
            asset.driveFileID = id
        }
    }

    /// Uploads everything that isn't in Drive yet (after connecting Google, or
    /// for files added while offline).
    @MainActor
    func backupAll(context: ModelContext) async {
        guard enabled else { status = "Drive backup is turned off."; return }
        guard AccountStore.shared.isGoogleSignedIn else { status = "Connect a Google account first."; return }
        guard AccountStore.shared.hasDriveScope else {
            status = "Reconnect Google to allow Drive access."
            return
        }
        let materials = (try? context.fetch(FetchDescriptor<StudyMaterial>())) ?? []
        let images = (try? context.fetch(FetchDescriptor<MoodBoardImage>())) ?? []
        let timetable = (try? context.fetch(FetchDescriptor<TimetableImageAsset>())) ?? []
        let todo = materials.filter { $0.driveFileID == nil }.count
            + images.filter { $0.driveFileID == nil }.count
            + timetable.filter { $0.driveFileID == nil }.count
        guard todo > 0 else {
            status = "Everything is already backed up to Drive."
            return
        }
        status = "Backing up \(todo) file\(todo == 1 ? "" : "s")…"
        for m in materials { await backup(m) }
        for i in images { await backup(i) }
        for t in timetable { await backup(t) }
        try? context.save()
        if !status.hasPrefix("Drive:") {
            status = "Backed up to Google Drive · \(Date().formatted(date: .omitted, time: .shortened))"
        }
    }

    // MARK: Deleting

    /// Moves a file LifeTracker uploaded into Drive's Bin — the same thing that
    /// happens when you delete it in Drive, so it can still be restored there
    /// for 30 days. Returns true when Drive confirmed it (or the file was
    /// already gone).
    @MainActor
    @discardableResult
    func remove(driveFileID id: String) async -> Bool {
        guard !id.isEmpty else { return false }
        guard isActive else {
            status = enabled ? "Connect Google to remove the Drive copy." : "Drive backup is turned off."
            return false
        }
        do {
            let token = try await AccountStore.shared.googleAccessToken()
            guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)") else { return false }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) || code == 404 {
                status = "Removed from Google Drive · \(Date().formatted(date: .omitted, time: .shortened))"
                return true
            }
            throw SyncError.server("Drive refused the delete (\(code)).")
        } catch {
            status = "Drive: \(error.localizedDescription)"
            return false
        }
    }

    /// Used by "Reset all data": moves every file LifeTracker ever uploaded —
    /// and the whole `LifeTracker` folder it made — into Drive's Bin. Call this
    /// *before* wiping the local database, while the Drive ids still exist.
    /// Returns how many files it removed.
    @MainActor
    @discardableResult
    func removeEverything(context: ModelContext) async -> Int {
        guard isActive else {
            status = AccountStore.shared.isGoogleSignedIn
                ? "Drive backup is off — nothing in Drive was changed."
                : "No Google account connected — nothing in Drive was changed."
            return 0
        }

        var ids: [String] = []
        if let items = try? context.fetch(FetchDescriptor<StudyMaterial>()) { ids += items.compactMap(\.driveFileID) }
        if let items = try? context.fetch(FetchDescriptor<MoodBoardImage>()) { ids += items.compactMap(\.driveFileID) }
        if let items = try? context.fetch(FetchDescriptor<TimetableImageAsset>()) { ids += items.compactMap(\.driveFileID) }

        var removed = 0
        if !ids.isEmpty {
            status = "Removing \(ids.count) file\(ids.count == 1 ? "" : "s") from Google Drive…"
            for id in ids {
                if await remove(driveFileID: id) { removed += 1 }
            }
        }

        // Then the folder itself, so nothing is left behind (including anything
        // uploaded by another device that this one never knew about).
        do {
            let token = try await AccountStore.shared.googleAccessToken()
            var root = folderCache["/LifeTracker"] ?? ""
            if root.isEmpty {
                root = try await findFolder("LifeTracker", parent: "root", token: token) ?? ""
            }
            if !root.isEmpty {
                _ = await remove(driveFileID: root)
            }
        } catch {
            // The folder may already be gone — nothing left to remove.
        }
        folderCache = [:]

        status = removed > 0
            ? "Removed \(removed) file\(removed == 1 ? "" : "s") and the LifeTracker folder from Drive's Bin."
            : "Removed the LifeTracker folder from Drive."
        return removed
    }

    @MainActor
    @discardableResult
    func remove(_ material: StudyMaterial) async -> Bool {
        guard let id = material.driveFileID else { return false }
        return await remove(driveFileID: id)
    }

    @MainActor
    @discardableResult
    func remove(_ image: MoodBoardImage) async -> Bool {
        guard let id = image.driveFileID else { return false }
        return await remove(driveFileID: id)
    }

    // MARK: Drive REST

    @MainActor
    private func upload(_ data: Data, name: String, ext: String, folder path: [String]) async -> String? {
        pendingUploads += 1
        isUploading = true
        defer {
            pendingUploads -= 1
            isUploading = pendingUploads > 0
        }
        do {
            let token = try await AccountStore.shared.googleAccessToken()
            let parent = try await folderID(for: path, token: token)
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"

            // 1) Start a resumable upload session (works for any size).
            var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
            start.httpMethod = "POST"
            start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            start.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
            start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
            start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
            let (_, startResp) = try await URLSession.shared.data(for: start)
            guard let http = startResp as? HTTPURLResponse, http.statusCode == 200,
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let uploadURL = URL(string: location) else {
                throw SyncError.server("Drive didn't accept the upload.")
            }

            // 2) Send the bytes.
            var put = URLRequest(url: uploadURL)
            put.httpMethod = "PUT"
            put.setValue(mime, forHTTPHeaderField: "Content-Type")
            let (body, putResp) = try await URLSession.shared.upload(for: put, from: data)
            guard let code = (putResp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = json["id"] as? String else {
                throw SyncError.server("Drive upload failed.")
            }
            return id
        } catch {
            status = "Drive: \(error.localizedDescription)"
            return nil
        }
    }

    /// Finds or creates each folder along `path`, caching the ids.
    @MainActor
    private func folderID(for path: [String], token: String) async throws -> String {
        var parent = "root"
        var key = ""
        for name in path {
            key += "/" + name
            if let cached = folderCache[key], await folderExists(cached, token: token) {
                parent = cached
                continue
            }
            var id = try await findFolder(name, parent: parent, token: token) ?? ""
            if id.isEmpty {
                id = try await createFolder(name, parent: parent, token: token)
            }
            var cache = folderCache
            cache[key] = id
            folderCache = cache
            parent = id
        }
        return parent
    }

    private func folderExists(_ id: String, token: String) async -> Bool {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=id,trashed")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else { return false }
        return (json["trashed"] as? Bool) != true
    }

    private func findFolder(_ name: String, parent: String, token: String) async throws -> String? {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        let q = "mimeType='application/vnd.google-apps.folder' and name='\(escaped)' and '\(parent)' in parents and trashed=false"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [.init(name: "q", value: q), .init(name: "fields", value: "files(id)"),
                            .init(name: "spaces", value: "drive")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let files = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [[String: Any]]
        return files?.first?["id"] as? String
    }

    private func createFolder(_ name: String, parent: String, token: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw SyncError.server("Couldn't create the Drive folder “\(name)”.")
        }
        return id
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Picks a sensible extension from image bytes.
    static func imageExtension(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.count >= 12, String(bytes: b[4..<12], encoding: .ascii)?.contains("ftyphei") == true { return "heic" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "jpg"
    }
}
