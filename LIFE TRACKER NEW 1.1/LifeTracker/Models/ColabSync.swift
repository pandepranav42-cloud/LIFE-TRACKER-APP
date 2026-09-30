import Foundation
import SwiftUI

// MARK: - Google Colab notebooks
//
// Colab notebooks are ordinary files in your Google Drive with a Colab-specific
// MIME type, so listing them is a Drive query. The catch: LifeTracker normally
// holds the `drive.file` scope, which only sees files the app itself created —
// your notebooks were made by Colab, so they're invisible under it. Listing
// them needs `drive.readonly`, which is why it's a separate opt-in connection
// rather than something the app asks for at sign-in.

struct ColabNotebook: Identifiable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let modifiedTime: Date?
    let byteCount: Int?
    let webViewLink: String?

    /// What it should be called in a repo.
    var fileName: String {
        name.lowercased().hasSuffix(".ipynb") ? name : "\(name).ipynb"
    }

    /// "Colab" for a real Colab notebook, "Jupyter" for a plain .ipynb.
    var origin: String {
        mimeType == ColabSync.colabMIME ? "Colab" : "Jupyter"
    }

    var openURL: URL? {
        if let webViewLink, let url = URL(string: webViewLink) { return url }
        return URL(string: "https://colab.research.google.com/drive/\(id)")
    }
}

final class ColabSync: ObservableObject {
    static let shared = ColabSync()

    static let colabMIME = "application/vnd.google.colaboratory"

    @Published private(set) var notebooks: [ColabNotebook] = []
    @Published var isLoading = false
    @Published var lastError: String?
    /// The notebook currently being fetched, so a row can show a spinner.
    @Published var busyID: String?

    private init() {}

    /// True when the notebooks can actually be listed.
    var isConnected: Bool { AccountStore.shared.isColabConnected }

    @MainActor
    func load() async {
        guard isConnected else {
            notebooks = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await AccountStore.shared.colabAccessToken()
            // Drive's `contains` matches whole words from the start, so the
            // leading dot in ".ipynb" would find nothing — search the bare
            // word and sort the results out below.
            let query = "(mimeType = '\(Self.colabMIME)' or name contains 'ipynb') and trashed = false"
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                .init(name: "q", value: query),
                .init(name: "orderBy", value: "modifiedTime desc"),
                .init(name: "pageSize", value: "100"),
                .init(name: "fields", value: "files(id,name,mimeType,modifiedTime,size,webViewLink)"),
                .init(name: "spaces", value: "drive"),
            ]
            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                if code == 401 || code == 403 {
                    throw SyncError.server("Google refused the listing — reconnect the Colab account and allow Drive access.")
                }
                throw SyncError.server("Google Drive returned \(code).")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = root["files"] as? [[String: Any]] else {
                notebooks = []
                return
            }

            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()

            notebooks = files.compactMap { item -> ColabNotebook? in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let mime = (item["mimeType"] as? String) ?? ""
                // Keep real notebooks only — the word search can drag in a
                // folder or a stray file that merely mentions "ipynb".
                guard mime == Self.colabMIME || name.lowercased().hasSuffix(".ipynb") else { return nil }
                let raw = item["modifiedTime"] as? String
                let modified = raw.flatMap { stamp.date(from: $0) ?? plain.date(from: $0) }
                let size = (item["size"] as? String).flatMap { Int($0) }
                return ColabNotebook(id: id,
                                     name: name,
                                     mimeType: mime,
                                     modifiedTime: modified,
                                     byteCount: size,
                                     webViewLink: item["webViewLink"] as? String)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            notebooks = []
        }
    }

    /// The notebook's actual .ipynb bytes.
    @MainActor
    func download(_ notebook: ColabNotebook) async throws -> Data {
        busyID = notebook.id
        defer { busyID = nil }
        let token = try await AccountStore.shared.colabAccessToken()
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(notebook.id)?alt=media") else {
            throw SyncError.server("Bad notebook id.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SyncError.server("Google Drive returned \(code) for that notebook.")
        }
        return data
    }
}
