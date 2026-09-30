import SwiftUI
import UniformTypeIdentifiers
import WebKit
import AuthenticationServices
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - GitHub page (Study → GitHub)
//
// Drop files or a folder, pick a repo (or make one), press Push. No commands,
// no clone, no staging area — the same three steps every time. Repositories
// open inside the app, so you can browse and download without a browser.

struct GitHubView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutWidth) private var width
    @ObservedObject private var hub = GitHubSync.shared
    @ObservedObject private var colab = ColabSync.shared
    @ObservedObject private var accounts = AccountStore.shared
    @Environment(\.webAuthenticationSession) private var webAuth

    @AppStorage("github.lastRepo") private var lastRepoFullName: String = ""

    @State private var selected: GitHubRepo?
    @State private var staged: [GitHubSync.Upload] = []
    @State private var folder = ""
    @State private var message = ""
    @State private var dropTargeted = false
    @State private var importing = false
    @State private var creatingRepo = false
    @State private var showToken = false
    @State private var search = ""
    @State private var deletingRepo: GitHubRepo?
    @State private var makingRelease: GitHubRepo?
    @State private var openRepo: GitHubRepo?
    @State private var showProfile = false
    /// Bumped after a push or release so the list below reloads.
    @State private var refreshTick = 0
    @State private var connectingColab = false
    /// Folders that already exist in the selected repo, for the destination menu.
    @State private var folders: [String] = []
    @State private var showAllNotebooks = false
    /// Files a drop or a pick couldn't read, with the reason macOS gave.
    @State private var stagingProblems: [String] = []

    /// How many notebooks the rail shows before you ask for the rest.
    private static let railPreview = 5
    @State private var toast: String?

    private var visibleRepos: [GitHubRepo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return hub.repos }
        return hub.repos.filter { $0.name.lowercased().contains(query) || $0.full_name.lowercased().contains(query) }
    }

    var body: some View {
        Group {
            if hub.isConnected {
                connected
            } else {
                GitHubConnectCard { showToken = true }
            }
        }
        .background(Palette.surface)
        .navigationTitle("GitHub & Colab")
        .blendedToolbar()
        .sheet(isPresented: $showToken) {
            GitHubTokenSheet { text in show(text) }
        }
        .sheet(item: $makingRelease) { repo in
            NewReleaseSheet(repo: repo, assets: staged) { published, attached in
                if attached { staged = [] }
                show("Published \(published.tag_name)")
                refreshTick += 1
            }
        }
        .sheet(isPresented: $creatingRepo) {
            NewRepoSheet { repo in
                selected = repo
                lastRepoFullName = repo.full_name
                show("Created \(repo.full_name)")
            }
        }
        .navigationDestination(item: $openRepo) { repo in
            RepoDetailView(repo: repo)
        }
        .navigationDestination(isPresented: $showProfile) {
            GitHubProfileView()
        }
        .task {
            if hub.isConnected && hub.repos.isEmpty { await hub.loadRepos() }
            restoreSelection()
            if colab.isConnected && colab.notebooks.isEmpty { await colab.load() }
            if let repo = selected, folders.isEmpty { await loadFolders(repo) }
        }
        .onChange(of: hub.repos) { _, _ in restoreSelection() }
        .confirmationDialog(deletingRepo.map { "Delete \($0.full_name)?" } ?? "Delete repository?",
                            isPresented: Binding(get: { deletingRepo != nil },
                                                 set: { if !$0 { deletingRepo = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingRepo) { repo in
            Button("Delete on GitHub", role: .destructive) {
                Task {
                    if await hub.deleteRepo(repo) {
                        if selected?.id == repo.id { selected = nil }
                        show("Deleted \(repo.full_name)")
                    } else {
                        show(hub.lastError ?? "Couldn't delete that repository")
                    }
                    deletingRepo = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingRepo = nil }
        } message: { _ in
            Text("This deletes the repository and everything in it on GitHub, for good. Your token needs the delete_repo scope.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.mono(12))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Palette.callout, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline))
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Connected layout

    private var connected: some View {
        ScrollView {
            Group {
                if width > 1120 {
                    HStack(alignment: .top, spacing: 20) {
                        // No vertical Divider here: inside a ScrollView it asks
                        // for unbounded height and takes the row's sizing with it.
                        mainColumn(withColab: false).frame(maxWidth: 800, alignment: .leading)
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(width: 1)
                            .frame(maxHeight: 600)
                        colabRail.frame(width: 300)
                    }
                } else {
                    // Narrow window: Colab sits inline near the top rather than
                    // under the repo list, where a long repo would bury it.
                    mainColumn(withColab: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            .padding(AppLayout.pagePadding(width))
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            acceptDrop(providers)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { stage(urls) }
        }
    }

    /// `withColab` folds the Colab section into this column — used when the
    /// window is too narrow for a side rail. It goes above the repositories,
    /// because notebooks are what you pick *before* choosing where to push.
    private func mainColumn(withColab: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            dropZone
            stagingProblemList
            if !staged.isEmpty { stagedList }
            if withColab {
                VStack(alignment: .leading, spacing: 20) {
                    colabRail
                    Divider().overlay(Palette.hairline)
                }
            }
            repoPicker
            if let repo = selected {
                Divider().overlay(Palette.hairline)
                RepoBrowser(repo: repo,
                            onNewRelease: { makingRelease = repo },
                            onUseFolder: { chosen in
                                folder = chosen
                                if !folders.contains(chosen) { folders.append(chosen) }
                                show(staged.isEmpty
                                     ? "Drop files and they'll go to /\(chosen)"
                                     : "\(staged.count) file\(staged.count == 1 ? "" : "s") will go to /\(chosen)")
                            },
                            stagedCount: staged.count)
                    .id("\(repo.id)-\(refreshTick)")
            }
        }
    }

    // MARK: Colab rail

    /// Your Colab notebooks, one tap from the push queue.
    private var colabRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("colab")
                Spacer()
                if colab.isLoading { ProgressView().controlSize(.small) }
                if colab.isConnected {
                    Button { Task { await colab.load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reload your notebooks from Drive")
                }
            }

            if !colab.isConnected {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color(hex: "E8710A"))
                    Text("Your Colab notebooks, here")
                        .font(.mono(13, .semibold))
                    Text("Tap one and it joins the push queue — then pick a repo and press Push. This is its own Google connection, so it can be your university account without touching the one doing Drive backups.")
                        .font(.mono(10))
                        .foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        connectColab()
                    } label: {
                        if connectingColab {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Connect a Google account", systemImage: "link")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "E8710A"))
                    .controlSize(.small)
                    .disabled(connectingColab)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudyPalette.line))
            } else if colab.notebooks.isEmpty && !colab.isLoading {
                Text("No notebooks in this Drive yet.")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
            } else {
                Text("Tap to add to the push queue")
                    .font(.mono(10)).foregroundStyle(Palette.mutedText)
                VStack(spacing: 6) {
                    ForEach(visibleNotebooks) { notebook in
                        notebookRow(notebook)
                    }
                }
                if colab.notebooks.count > Self.railPreview {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showAllNotebooks.toggle() }
                    } label: {
                        Label(showAllNotebooks
                              ? "Show the 5 newest"
                              : "View all \(colab.notebooks.count)",
                              systemImage: showAllNotebooks ? "chevron.up" : "chevron.down")
                            .font(.mono(11))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error = colab.lastError {
                Text(error)
                    .font(.mono(10)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var visibleNotebooks: [ColabNotebook] {
        showAllNotebooks ? colab.notebooks : Array(colab.notebooks.prefix(Self.railPreview))
    }

    private func notebookRow(_ notebook: ColabNotebook) -> some View {
        let isStaged = staged.contains { $0.remotePath == notebook.fileName }
        return HStack(spacing: 9) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "E8710A"))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(notebook.name)
                    .font(.mono(11, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(notebook.origin)
                    if let date = notebook.modifiedTime {
                        Text(date.formatted(.dateTime.day().month(.abbreviated)))
                    }
                    if let size = notebook.byteCount, size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                }
                .font(.mono(9))
                .foregroundStyle(Palette.mutedText)
            }
            Spacer(minLength: 4)
            if colab.busyID == notebook.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    downloadNotebook(notebook)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Download \(notebook.fileName) to this device")

                Image(systemName: isStaged ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isStaged ? Color(hex: "2DA44E") : Palette.mutedText)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isStaged ? Color(hex: "2DA44E").opacity(0.5) : Palette.hairline))
        .contentShape(Rectangle())
        .onTapGesture { if !isStaged { stage(notebook) } }
        .contextMenu {
            Button("Add to files to push") { stage(notebook) }
            if let repo = selected {
                Button("Push straight to \(repo.name)") { stage(notebook, thenPushTo: repo) }
            }
            Button("Download the notebook") { downloadNotebook(notebook) }
            Button("Open in Colab") {
                if let url = notebook.openURL { openURL(url) }
            }
        }
        .help("Add \(notebook.fileName) to the files waiting to be pushed")
    }

    /// "Add Colab" until an account is connected, then a menu showing which
    /// one, with switch and disconnect.
    @ViewBuilder
    private var colabAccountButton: some View {
        if connectingColab {
            ProgressView().controlSize(.small)
        } else if accounts.isColabConnected {
            Menu {
                Text(accounts.colabEmail ?? "Connected")
                Button("Reload notebooks") { Task { await colab.load() } }
                Button("Use a different account…") { connectColab() }
                Divider()
                Button("Disconnect Colab account", role: .destructive) {
                    Task { @MainActor in
                        accounts.disconnectColabAccount()
                        await colab.load()
                        show("Colab account disconnected")
                    }
                }
            } label: {
                Label("Colab", systemImage: "sparkles.rectangle.stack.fill")
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Notebooks from \(accounts.colabEmail ?? "your Google account")")
        } else {
            Button {
                connectColab()
            } label: {
                Label("Add Colab", systemImage: "sparkles.rectangle.stack")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Connect the Google account your Colab notebooks live in — it can be a different address from the one you signed in with")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                showProfile = true
            } label: {
                HStack(spacing: 12) {
                    GitHubAvatar(url: hub.user?.avatar_url, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hub.user?.displayName ?? "GitHub")
                            .font(.mono(18, .bold))
                            .foregroundStyle(.primary)
                        Text("@\(hub.user?.login ?? "") · \(hub.repos.count) repositor\(hub.repos.count == 1 ? "y" : "ies") · profile →")
                            .font(.mono(11)).foregroundStyle(Palette.mutedText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Your profile, contribution graph and bio")

            Spacer()
            if hub.isBusy { ProgressView().controlSize(.small) }

            // The Google account your Colab notebooks live in — its own
            // connection, so a university address can sit beside the personal
            // account doing Drive backups.
            colabAccountButton

            Button { Task { await hub.loadRepos() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reload your repositories")
            Menu {
                Button("Open GitHub in browser") {
                    if let url = URL(string: "https://github.com/\(hub.user?.login ?? "")") { openURL(url) }
                }
                Button("Change token…") { showToken = true }
                Divider()
                Button("Disconnect", role: .destructive) {
                    Task { @MainActor in
                        hub.disconnect()
                        selected = nil
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .frame(width: 32)
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        Button { importing = true } label: {
            VStack(spacing: 10) {
                Image(systemName: dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(.system(size: 30, weight: .light))
                Text(staged.isEmpty ? "Drop files or a folder here" : "Drop more")
                    .font(.mono(15, .semibold))
                Text("Any file type. A folder keeps its structure — drop “Sem5” and the repo gets Sem5/… exactly as it is on disk.")
                    .font(.mono(11)).multilineTextAlignment(.center)
                    .foregroundStyle(Palette.mutedText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, staged.isEmpty ? 44 : 26)
            .background(dropTargeted ? StudyPalette.callout : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Palette.accent : StudyPalette.line,
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A Button eats the drag before the page behind it sees it, so the
        // dashed box has to accept the drop itself.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            acceptDrop(providers)
        }
    }

    /// Files that didn't make it into the queue, and why. Shown right under
    /// the drop zone rather than inside the staged list, because when macOS
    /// refuses everything there is no staged list to put it in.
    @ViewBuilder
    private var stagingProblemList: some View {
        if !stagingProblems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text("\(stagingProblems.count) file\(stagingProblems.count == 1 ? "" : "s") couldn't be read")
                        .font(.mono(11, .semibold))
                    Spacer()
                    Button("Dismiss") { stagingProblems = [] }
                        .buttonStyle(.borderless)
                        .font(.mono(10))
                }
                .foregroundStyle(Color(hex: "B07C2E"))

                ForEach(Array(stagingProblems.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.mono(10))
                        .foregroundStyle(Palette.mutedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("macOS asks once, per folder, before an app may read Desktop, Documents or Downloads. If you never saw that prompt, turn LifeTracker on under System Settings → Privacy & Security → Files and Folders.")
                    .font(.mono(10))
                    .foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(StudyPalette.callout, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudyPalette.line))
        }
    }

    // MARK: Staged files

    private var stagedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("ready to push")
                Spacer()
                Text("\(staged.count) file\(staged.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(staged.reduce(0) { $0 + $1.byteCount }), countStyle: .file))")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
                Button("Clear") { staged = []; stagingProblems = [] }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hub.isBusy)
            }

            VStack(spacing: 6) {
                ForEach(staged) { item in
                    HStack(spacing: 10) {
                        Image(systemName: MaterialKind.of((item.remotePath as NSString).pathExtension).icon)
                            .font(.system(size: 13))
                            .foregroundStyle(MaterialKind.of((item.remotePath as NSString).pathExtension).color)
                            .frame(width: 20)
                        Text(item.remotePath)
                            .font(.mono(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if item.byteCount > GitHubSync.maxUploadBytes {
                            Text("too big to push")
                                .font(.mono(10, .semibold))
                                .foregroundStyle(Color(hex: "C0453F"))
                                .help("Over 50 MB — attach it to a release instead")
                        } else {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                                .font(.mono(10)).foregroundStyle(Palette.mutedText)
                        }
                        Button(role: .destructive) {
                            staged.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.mutedText)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(hub.isBusy)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { folderField; messageField; pushButton; releaseButton }
                VStack(spacing: 8) {
                    folderField
                    messageField
                    HStack(spacing: 8) { pushButton; releaseButton }
                }
            }

            Text(destinationSummary)
                .font(.mono(10))
                .foregroundStyle(Palette.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)

            if hub.isBusy { transferMeter }
            if let error = hub.lastError {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            pushReport
        }
        .padding(16)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudyPalette.line))
    }

    /// What the last push actually did, step by step. A push that claims to
    /// have worked should be something you can go and look at — so the commit
    /// link is here, and the whole list is copyable when it isn't.
    @ViewBuilder
    private var pushReport: some View {
        if let url = hub.lastCommitURL {
            Link(destination: url) {
                Label("See the commit on GitHub", systemImage: "arrow.up.forward.square")
                    .font(.mono(11))
            }
            .foregroundStyle(Palette.accent)
        }
        if !hub.pushLog.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(hub.pushLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.mono(10))
                            .foregroundStyle(line.contains("FAILED") || line.contains("NOT verified")
                                             ? Color(hex: "C0453F") : Palette.mutedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        Platform.copy(hub.pushLog.joined(separator: "\n"))
                        show("Copied the push details")
                    } label: {
                        Label("Copy these details", systemImage: "doc.on.doc")
                            .font(.mono(10))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            } label: {
                Text("What the push did")
                    .font(.mono(10))
                    .foregroundStyle(Palette.mutedText)
            }
        }
    }

    private var transferMeter: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: hub.progress)
                .tint(Palette.accent)
            Text(hub.progressLabel.isEmpty ? "Working…" : hub.progressLabel)
                .font(.mono(10)).foregroundStyle(Palette.mutedText)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// Where in the repo the files land — ONE control, not two.
    ///
    /// Type a folder, or press the chevron to pick one the repo already has.
    /// Leave it empty and the files go to the top of the repository, which is
    /// what pushing did before folders existed.
    private var folderField: some View {
        HStack(spacing: 0) {
            TextField("Folder (optional) — leave empty for the top of the repo", text: $folder)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            Menu {
                Button("Top of the repository") { folder = "" }
                if !folders.isEmpty {
                    Divider()
                    ForEach(folders, id: \.self) { path in
                        Button(path) { folder = path }
                    }
                }
                if selected != nil {
                    Divider()
                    Button("Look again") {
                        if let repo = selected { Task { await loadFolders(repo) } }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.mutedText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(selected == nil)
            .help("Folders already in this repo")
        }
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline))
    }

    private var messageField: some View {
        TextField("Commit message (optional)", text: $message)
            .textFieldStyle(.roundedBorder)
            .font(.mono(12))
    }

    private var pushButton: some View {
        Button {
            push()
        } label: {
            Label(pushLabel, systemImage: "arrow.up.circle.fill")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(hex: "2DA44E"))
        .disabled(selected == nil || staged.isEmpty || hub.isBusy)
    }

    private var pushLabel: String {
        guard let repo = selected else { return "Pick a repo" }
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !prefix.isEmpty else { return "Push to \(repo.name)" }
        return "Push to \((prefix as NSString).lastPathComponent)"
    }

    private var releaseButton: some View {
        Button {
            makingRelease = selected
        } label: {
            Label("Release", systemImage: "shippingbox.fill")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .disabled(selected == nil || hub.isBusy)
        .help("Publish these files as a downloadable version instead of committing them")
    }

    // MARK: Repo picker

    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("repositories")
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(11))
                    .frame(maxWidth: 180)
                Button { creatingRepo = true } label: {
                    Label("New repo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(StudyPalette.brown)
                .controlSize(.small)
            }

            if hub.repos.isEmpty && !hub.isBusy {
                Text("No repositories yet — make one with New repo and push straight into it.")
                    .font(.mono(12)).foregroundStyle(Palette.mutedText)
            } else {
                Text("Tap a repo to push into it · ➔ opens it here, with its files, releases and downloads")
                    .font(.mono(10)).foregroundStyle(Palette.mutedText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)], spacing: 12) {
                ForEach(visibleRepos) { repo in
                    RepoCard(repo: repo,
                             isSelected: selected?.id == repo.id,
                             onOpen: { openRepo = repo },
                             onDelete: { deletingRepo = repo })
                        .onTapGesture {
                            selected = repo
                            lastRepoFullName = repo.full_name
                            folder = ""
                            Task { await loadFolders(repo) }
                        }
                        .contextMenu {
                            Button("Open in LifeTracker") { openRepo = repo }
                            Button("Open on github.com") {
                                if let url = URL(string: repo.html_url) { openURL(url) }
                            }
                            Button("Copy clone URL") { Platform.copy("\(repo.html_url).git") }
                            Divider()
                            Button("Delete repository…", role: .destructive) { deletingRepo = repo }
                        }
                }
            }
        }
    }

    // MARK: Actions

    private func heading(_ text: String) -> some View {
        Text(text.lowercased())
            .font(.mono(14, .bold))
            .italic()
            .foregroundStyle(Palette.accent)
    }

    /// "SEM-V-LAB-CODES / CV LAB (SEM V) / notes.ipynb"
    private var destinationSummary: String {
        guard let repo = selected else { return "Pick a repo below to choose where these files go." }
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let place = prefix.isEmpty ? repo.name : "\(repo.name)/\(prefix)"
        // The whole remote path, not just the file name — a dropped folder
        // keeps its structure, and the preview should show where it lands.
        let first = staged.first?.remotePath ?? "your files"
        return staged.count > 1
            ? "Going to \(place) — \(staged.count) files"
            : "Going to \(place)/\(first)"
    }

    /// The folders already in the repo, two levels deep — enough to cover
    /// "CV LAB (SEM V)" and a sub-folder inside it without hammering the API.
    @MainActor
    private func loadFolders(_ repo: GitHubRepo) async {
        var found = (await hub.contents(of: repo, path: "")).filter(\.isDirectory).map(\.path)
        let roots = found
        for path in roots.prefix(8) {
            let children = await hub.contents(of: repo, path: path)
            found += children.filter(\.isDirectory).map(\.path)
        }
        folders = Array(Set(found)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func restoreSelection() {
        guard selected == nil, !lastRepoFullName.isEmpty,
              let match = hub.repos.first(where: { $0.full_name == lastRepoFullName }) else { return }
        selected = match
        Task { await loadFolders(match) }
    }

    private func stage(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Hold the permission the drop or the picker granted for as long as we
        // are looking at these files. Note the `where` is gone: a URL that
        // isn't security-scoped returns false here and is still perfectly
        // readable — the old code only kept the scoped ones and dropped the
        // rest on the floor.
        var accessed: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() { accessed.append(url) }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        let expanded = GitHubSync.expand(urls, into: "")
        guard !expanded.isEmpty else {
            show(unreadableReason(urls))
            return
        }

        // Copy the bytes now, while the drop still grants access. By the time
        // you press Push that permission is gone and the originals would be
        // unreadable — which is how a "successful" push ends up empty.
        let root: URL
        do {
            root = try GitHubSync.newStagingFolder()
        } catch {
            show("Couldn't make a staging folder: \(error.localizedDescription)")
            return
        }

        var copies: [GitHubSync.Upload] = []
        var refused: [String] = []
        for item in expanded {
            do {
                copies.append(try GitHubSync.stageCopy(of: item, into: root))
            } catch {
                refused.append("\((item.remotePath as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !copies.isEmpty else {
            // Say what macOS actually objected to. "Couldn't read those files"
            // with no reason is how this went unnoticed for a whole OS
            // upgrade — the failure has to name itself.
            show(refused.first ?? unreadableReason(urls))
            stagingProblems = refused
            return
        }
        stagingProblems = refused
        if !refused.isEmpty {
            show("Added \(copies.count), but \(refused.count) couldn't be read — see below")
        }
        let existing = Set(staged.map(\.remotePath))
        staged += copies.filter { !existing.contains($0.remotePath) }
    }

    /// Why nothing came out of a drop. Almost always one of two things on a
    /// recent macOS: the folder needs the permission System Settings hands
    /// out under Privacy & Security → Files and Folders, or the drop carried
    /// something that isn't a file at all.
    private func unreadableReason(_ urls: [URL]) -> String {
        let fm = FileManager.default
        let missing = urls.filter { !fm.fileExists(atPath: $0.standardizedFileURL.path) }
        if !missing.isEmpty, let first = missing.first {
            let folder = first.deletingLastPathComponent().lastPathComponent
            return "macOS won't let LifeTracker read \(folder.isEmpty ? "that folder" : "“\(folder)”"). Allow it under System Settings → Privacy & Security → Files and Folders, then drop again."
        }
        return "Nothing readable in that drop"
    }

    /// Finder's own drag payload. `dropDestination(for: URL.self)` asks
    /// SwiftUI to decode a `URL` value, which on recent macOS can arrive as a
    /// plain path with none of the access that came with the drag. Taking the
    /// `public.file-url` item straight off the provider is what AppKit itself
    /// does, and it keeps the permission attached.
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let type = UTType.fileURL.identifier
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !wanted.isEmpty else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in wanted {
                if let url = await Self.fileURL(from: provider, type: type) { urls.append(url) }
            }
            if urls.isEmpty {
                show("That drop didn't carry any files LifeTracker can open")
            } else {
                stage(urls)
            }
        }
        return true
    }

    /// A `public.file-url` item comes back as an `NSURL`, or as the bytes of
    /// one, or occasionally as a plain string. All three are handled; nothing
    /// else is a file.
    private static func fileURL(from provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type) { item, _ in
                var found: URL?
                if let nsurl = item as? NSURL {
                    found = nsurl as URL
                } else if let data = item as? NSData,
                          let url = URL(dataRepresentation: data as Data, relativeTo: nil) {
                    found = url
                } else if let text = item as? NSString {
                    found = URL(string: text as String)
                }
                continuation.resume(returning: found?.isFileURL == true ? found : nil)
            }
        }
    }

    /// Asks Google for the extra read permission, then lists the notebooks.
    private func connectColab() {
        connectingColab = true
        Task { @MainActor in
            if await accounts.connectColabAccount(using: webAuth) {
                await colab.load()
                let who = accounts.colabEmail ?? "that account"
                show(colab.notebooks.isEmpty
                     ? "Connected \(who) — no notebooks found"
                     : "\(colab.notebooks.count) notebook\(colab.notebooks.count == 1 ? "" : "s") from \(who)")
            } else {
                show(accounts.lastError ?? "Google didn't grant access")
            }
            connectingColab = false
        }
    }

    /// Downloads the notebook and drops it in the push queue, exactly as if
    /// you'd dragged the .ipynb in from disk.
    private func stage(_ notebook: ColabNotebook, thenPushTo repo: GitHubRepo? = nil) {
        Task { @MainActor in
            do {
                let data = try await colab.download(notebook)
                let stagingDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GitHubStaging/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                let url = stagingDir.appendingPathComponent(notebook.fileName)
                try data.write(to: url)

                if !staged.contains(where: { $0.remotePath == notebook.fileName }) {
                    staged.append(GitHubSync.Upload(localURL: url,
                                                    remotePath: notebook.fileName,
                                                    byteCount: data.count))
                }
                if let repo {
                    selected = repo
                    push()
                } else {
                    show("Added \(notebook.fileName) — pick a repo and press Push")
                }
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    /// Saves the .ipynb straight to disk — Mac asks where, iPad hands it to
    /// the share sheet.
    private func downloadNotebook(_ notebook: ColabNotebook) {
        Task { @MainActor in
            do {
                let data = try await colab.download(notebook)
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ColabDownloads/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(notebook.fileName)
                try data.write(to: url)
                #if os(macOS)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = notebook.fileName
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let destination = panel.url {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: url, to: destination)
                    try? FileManager.default.removeItem(at: folder)
                    show("Saved \(destination.lastPathComponent)")
                }
                #else
                ShareTools.share([url])
                show("Downloaded \(notebook.fileName)")
                #endif
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func push() {
        guard let repo = selected else { return }
        let prefix = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let uploads = staged.map { item -> GitHubSync.Upload in
            var copy = item
            if !prefix.isEmpty { copy.remotePath = "\(prefix)/\(item.remotePath)" }
            return copy
        }
        Task { @MainActor in
            let failures = await hub.push(uploads, to: repo, message: message)
            if failures.isEmpty {
                staged = []
                message = ""
                refreshTick += 1
                show("Pushed \(uploads.count) file\(uploads.count == 1 ? "" : "s") to \(repo.name)")
            } else {
                staged = staged.filter { item in
                    failures.contains { $0.0.hasSuffix(item.remotePath) }
                }
                show("\(failures.count) file\(failures.count == 1 ? "" : "s") didn't go through")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Repo card

private struct RepoCard: View {
    let repo: GitHubRepo
    let isSelected: Bool
    var onOpen: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book")
                    .font(.system(size: 11))
                    .foregroundStyle(repo.isPrivate ? StudyPalette.brown : Palette.mutedText)
                Text(repo.name)
                    .font(.mono(13, .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "2DA44E"))
                }
            }
            Text(repo.description?.isEmpty == false ? repo.description! : "No description")
                .font(.mono(10))
                .foregroundStyle(Palette.mutedText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
            HStack(spacing: 6) {
                Text(repo.branch)
                    .font(.mono(9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.subtleFill, in: Capsule())
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    Image(systemName: "arrow.forward.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this repository in LifeTracker")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Color(hex: "C0453F") : Palette.mutedText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this repository on GitHub")
            }
        }
        .padding(12)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color(hex: "2DA44E") : (hovering ? StudyPalette.brown.opacity(0.5) : StudyPalette.line),
                          lineWidth: isSelected ? 1.8 : 1))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

// MARK: - Connect card

private struct GitHubConnectCard: View {
    var onConnect: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 60, height: 60)
                .background(Color(hex: "24292F"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Push to GitHub without the commands")
                .font(.mono(17, .bold))
            Text("Drop a file or a folder, pick a repo, press Push. LifeTracker commits it for you.")
                .font(.mono(12))
                .foregroundStyle(Palette.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onConnect) {
                Label("Connect GitHub", systemImage: "key.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "24292F"))
        }
        .padding(30)
        .frame(maxWidth: 460)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Token sheet

private struct GitHubTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var hub = GitHubSync.shared

    var onMessage: (String) -> Void

    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    private let newTokenURL = "https://github.com/settings/tokens/new?scopes=repo,delete_repo,user&description=LifeTracker"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect GitHub").font(.mono(16, .bold))
            Text("LifeTracker uses a personal access token — the same thing the GitHub CLI uses. It's kept in this device's Keychain and never goes into an export file.")
                .font(.mono(11)).foregroundStyle(Palette.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("1 · Make a token").font(.mono(12, .semibold))
                Text("Open the link below — **repo**, **delete_repo** and **user** are ticked for you. `repo` pushes and downloads, `delete_repo` lets the app delete repositories, `user` shows your contribution graph and lets you edit your bio. Pick an expiry, then Generate.")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: newTokenURL) { openURL(url) }
                } label: {
                    Label("Open GitHub token page", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.callout, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text("2 · Paste it here").font(.mono(12, .semibold))
                HStack(spacing: 6) {
                    SecureField("ghp_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .font(.mono(12))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Button("Paste") {
                        if let clip = Platform.pastedString() { token = clip.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty || busy)
            }
        }
        .padding(20)
        .sheetFrame(width: 500, height: 420)
    }

    private func connect() {
        busy = true
        error = nil
        Task { @MainActor in
            if await hub.connect(token: token) {
                onMessage("Connected as @\(hub.user?.login ?? "")")
                dismiss()
            } else {
                error = hub.lastError ?? "GitHub wouldn't accept that token."
            }
            busy = false
        }
    }
}

// MARK: - New release sheet

/// Publishes a version: a tag, notes, and whatever files you dropped attached
/// as downloads. Release assets go up to 2 GB each, so a whole .dmg or .ipa is
/// fine here even though the plain file push stops at 50 MB.
private struct NewReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = GitHubSync.shared

    let repo: GitHubRepo
    let assets: [GitHubSync.Upload]
    /// (release, whether the staged files were attached)
    var onPublished: (GitHubRelease, Bool) -> Void

    @State private var tag = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var attach = true
    @State private var isDraft = false
    @State private var isPrerelease = false
    @State private var busy = false
    @State private var error: String?

    private var totalBytes: Int { assets.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New release").font(.mono(16, .bold))
            Text("Publishes to \(repo.full_name) from \(repo.branch).")
                .font(.mono(11)).foregroundStyle(Palette.mutedText)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TAG").font(.mono(10, .semibold)).foregroundStyle(Palette.mutedText)
                    TextField("v1.0", text: $tag)
                        .textFieldStyle(.roundedBorder)
                        .font(.mono(12))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                .frame(width: 120)
                VStack(alignment: .leading, spacing: 5) {
                    Text("TITLE").font(.mono(10, .semibold)).foregroundStyle(Palette.mutedText)
                    TextField(tag.isEmpty ? "Version name" : tag, text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(.mono(12))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("WHAT'S NEW").font(.mono(10, .semibold)).foregroundStyle(Palette.mutedText)
                TextEditor(text: $notes)
                    .font(.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 96)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
            }

            if assets.isEmpty {
                Label("No files staged — this will be notes only. Drop a build on the GitHub page first to attach downloads.",
                      systemImage: "info.circle")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle(isOn: $attach) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Attach the \(assets.count) staged file\(assets.count == 1 ? "" : "s")")
                            .font(.mono(12, .medium))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)) — people download these straight from the release page.")
                            .font(.mono(10)).foregroundStyle(Palette.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 18) {
                Toggle("Draft", isOn: $isDraft)
                    .help("Saved on GitHub but not visible to anyone else yet")
                Toggle("Pre-release", isOn: $isPrerelease)
                    .help("Marked as not production-ready")
                Spacer()
            }
            .font(.mono(12))

            if busy {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: hub.progress)
                        .tint(Color(hex: "8250DF"))
                    Text(hub.progressLabel.isEmpty ? "Uploading…" : hub.progressLabel)
                        .font(.mono(10)).foregroundStyle(Palette.mutedText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let error {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button("Publish") { publish() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "8250DF"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .sheetFrame(width: 520, height: 560)
        .task {
            // Suggest the next version by looking at the newest release.
            let existing = await hub.releases(for: repo)
            guard tag.isEmpty else { return }
            guard let latest = existing.first?.tag_name, !latest.isEmpty else { tag = "v1.0"; return }
            let prefix = latest.hasPrefix("v") ? "v" : ""
            let parts = latest.dropFirst(prefix.count).components(separatedBy: ".")
            if let last = parts.last, let number = Int(last) {
                tag = prefix + (parts.dropLast() + ["\(number + 1)"]).joined(separator: ".")
            } else {
                tag = latest + ".1"
            }
        }
    }

    private func publish() {
        busy = true
        error = nil
        Task { @MainActor in
            let files = (attach && !assets.isEmpty) ? assets : []
            if let release = await hub.createRelease(in: repo, tag: tag, title: title, notes: notes,
                                                     isDraft: isDraft, isPrerelease: isPrerelease,
                                                     assets: files) {
                onPublished(release, !files.isEmpty && hub.lastError == nil)
                dismiss()
            } else {
                error = hub.lastError ?? "GitHub wouldn't create that release."
            }
            busy = false
        }
    }
}

// MARK: - New repo sheet

private struct NewRepoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = GitHubSync.shared

    var onCreated: (GitHubRepo) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = true
    @State private var addReadme = true
    @State private var busy = false
    @State private var error: String?

    private var slug: String { GitHubSync.slug(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New repository").font(.mono(16, .bold))

            VStack(alignment: .leading, spacing: 5) {
                FormTextField("Name", text: $name)
                if !name.isEmpty && slug != name {
                    Text("GitHub will call it “\(slug)”.")
                        .font(.mono(10)).foregroundStyle(Palette.mutedText)
                }
            }
            FormTextField("Description (optional)", text: $description)

            Toggle(isOn: $isPrivate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private").font(.mono(12, .medium))
                    Text("Only you can see it. Turn this off to make it public.")
                        .font(.mono(10)).foregroundStyle(Palette.mutedText)
                }
            }
            Toggle(isOn: $addReadme) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start with a README").font(.mono(12, .medium))
                    Text("Gives the repo a first commit, so pushing files works immediately.")
                        .font(.mono(10)).foregroundStyle(Palette.mutedText)
                }
            }

            if let error {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(slug.isEmpty || busy)
            }
        }
        .padding(20)
        .sheetFrame(width: 460, height: 380)
    }

    private func create() {
        busy = true
        error = nil
        Task { @MainActor in
            if let repo = await hub.createRepo(name: name, description: description,
                                               isPrivate: isPrivate, addReadme: addReadme) {
                onCreated(repo)
                dismiss()
            } else {
                error = hub.lastError ?? "Couldn't create that repository."
            }
            busy = false
        }
    }
}

// MARK: - Files, releases and downloads for one repo
//
// Used twice: inline under the repo grid for whichever repo is selected, and
// again as the body of the full repository page. One implementation, so the
// two can't drift apart.

private struct RepoBrowser: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var hub = GitHubSync.shared

    let repo: GitHubRepo
    /// Tapped on the "New release" button; nil hides it.
    var onNewRelease: (() -> Void)? = nil
    /// "Push here" — hands the folder you're browsing back as the destination.
    var onUseFolder: ((String) -> Void)? = nil
    /// How many staged files the release button would attach.
    var stagedCount: Int = 0

    @State private var path = ""
    @State private var entries: [GitHubEntry] = []
    @State private var releases: [GitHubRelease] = []
    @State private var loadingFiles = false
    @State private var loadingReleases = false
    @State private var downloadName: String?
    @State private var downloadProgress: Double = 0
    @State private var deletingEntry: GitHubEntry?
    @State private var deletingRelease: GitHubRelease?
    @State private var editingFile: EditableFile?
    @State private var toast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            releaseSection
            fileSection
        }
        .sheet(item: $editingFile) { wrapper in
            TextFileEditor(repo: repo, file: wrapper.file) { saved in
                editingFile = nil
                if saved {
                    show("Saved \(wrapper.file.path)")
                    Task { await loadFiles() }
                }
            }
        }
        .task(id: repo.id) { await reload() }
        .confirmationDialog(deletingEntry.map { "Delete “\($0.name)”?" } ?? "Delete file?",
                            isPresented: Binding(get: { deletingEntry != nil },
                                                 set: { if !$0 { deletingEntry = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingEntry) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    if await hub.delete(entry, in: repo, message: "Delete \(entry.name)") {
                        show("Deleted \(entry.name)")
                        await loadFiles()
                    } else {
                        show(hub.lastError ?? "Couldn't delete that file")
                    }
                    deletingEntry = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingEntry = nil }
        } message: { _ in
            Text("It's removed with a commit. The history keeps the old version.")
        }
        .confirmationDialog(deletingRelease.map { "Delete release \($0.tag_name)?" } ?? "Delete release?",
                            isPresented: Binding(get: { deletingRelease != nil },
                                                 set: { if !$0 { deletingRelease = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingRelease) { release in
            Button("Delete release", role: .destructive) {
                Task {
                    if await hub.deleteRelease(release, in: repo) {
                        show("Deleted \(release.tag_name)")
                        await loadReleases()
                    } else {
                        show(hub.lastError ?? "Couldn't delete that release")
                    }
                    deletingRelease = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingRelease = nil }
        } message: { _ in
            Text("The release and its downloads go. The git tag stays on the repository.")
        }
        .overlay(alignment: .bottom) { status }
    }

    /// Call after pushing or publishing from outside, to pick up the change.
    @MainActor
    func reload() async {
        await loadFiles()
        await loadReleases()
    }

    // MARK: Releases

    private var releaseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("releases")
                Spacer()
                if loadingReleases { ProgressView().controlSize(.small) }
                if let onNewRelease {
                    Button(action: onNewRelease) {
                        Label(stagedCount > 0
                              ? "Release \(stagedCount) file\(stagedCount == 1 ? "" : "s")"
                              : "New release",
                              systemImage: "shippingbox.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "8250DF"))
                    .controlSize(.small)
                    .help("Publish a version with these files attached for download")
                }
            }

            if releases.isEmpty && !loadingReleases {
                Text(stagedCount > 0
                     ? "Press the button to publish those \(stagedCount) file\(stagedCount == 1 ? "" : "s") as a downloadable release."
                     : "No releases yet. Drop a build (.zip, .dmg, .ipa…) and press New release to publish it.")
                    .font(.mono(12)).foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(releases) { release in
                    releaseRow(release)
                }
            }
        }
    }

    private func releaseRow(_ release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: release.draft ? "shippingbox" : "shippingbox.fill")
                    .foregroundStyle(release.draft ? Palette.mutedText : Color(hex: "8250DF"))
                Text(release.title).font(.mono(13, .semibold)).lineLimit(1)
                Text(release.tag_name)
                    .font(.mono(10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.subtleFill, in: Capsule())
                if release.draft || release.prerelease {
                    Text(release.draft ? "draft" : "pre-release")
                        .font(.mono(9, .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.subtleFill, in: Capsule())
                }
                Spacer(minLength: 6)
                Button {
                    if let url = URL(string: release.html_url) { openURL(url) }
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this release on GitHub")
                Button(role: .destructive) {
                    deletingRelease = release
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this release")
            }

            if let notes = release.body, !notes.isEmpty {
                Text(notes)
                    .font(.mono(11))
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(release.assets ?? []) { asset in
                assetRow(asset)
            }
        }
        .padding(10)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }

    private func assetRow(_ asset: GitHubRelease.Asset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 11))
                .foregroundStyle(Palette.mutedText)
            Text(asset.name).font(.mono(11)).lineLimit(1)
            Spacer(minLength: 6)
            Text(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                .font(.mono(10)).foregroundStyle(Palette.mutedText)
            if let count = asset.download_count {
                Text("\(count) ↓").font(.mono(10)).foregroundStyle(Palette.mutedText)
            }
            Button {
                Platform.copy(asset.browser_download_url)
                show("Download link copied")
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.mutedText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy the direct download link")
            Button {
                downloadAsset(asset)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(downloadName != nil)
            .help("Download this build")
        }
        .padding(.leading, 22)
    }

    // MARK: Files

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                heading("files in \(repo.name)")
                Spacer()
                if loadingFiles { ProgressView().controlSize(.small) }
                if let onUseFolder, !path.isEmpty {
                    Button {
                        onUseFolder(path)
                    } label: {
                        Label("Push here", systemImage: "arrow.up.circle")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "2DA44E"))
                    .controlSize(.small)
                    .help("Send the files waiting to be pushed into this folder")
                }
                Button {
                    openReadme()
                } label: {
                    Label(hasReadme ? "Edit README" : "Add README", systemImage: "doc.text")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Write the README that shows on the repo's front page")
                if !path.isEmpty {
                    Button {
                        path = (path as NSString).deletingLastPathComponent
                        Task { await loadFiles() }
                    } label: {
                        Label("Up", systemImage: "arrow.turn.left.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !path.isEmpty {
                Text("/\(path)").font(.mono(11)).foregroundStyle(Palette.mutedText).lineLimit(1)
            }

            if entries.isEmpty && !loadingFiles {
                Text("Nothing here yet.")
                    .font(.mono(12)).foregroundStyle(Palette.mutedText)
            }

            VStack(spacing: 6) {
                ForEach(entries) { entry in
                    fileRow(entry)
                }
            }

            if !entries.isEmpty {
                Text(path.isEmpty
                     ? "Tap a folder to open it · ⬇ downloads · 🗑 removes it with a commit"
                     : "Push here sends the staged files into /\(path)")
                    .font(.mono(10)).foregroundStyle(Palette.mutedText)
            }
        }
    }

    private func fileRow(_ entry: GitHubEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory
                  ? "folder.fill"
                  : MaterialKind.of((entry.name as NSString).pathExtension).icon)
                .font(.system(size: 13))
                .foregroundStyle(entry.isDirectory
                                 ? StudyPalette.brown
                                 : MaterialKind.of((entry.name as NSString).pathExtension).color)
                .frame(width: 20)
            Text(entry.name).font(.mono(12)).lineLimit(1)
            Spacer(minLength: 8)
            if let size = entry.size, !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.mono(10)).foregroundStyle(Palette.mutedText)
            }
            if let link = entry.html_url, let url = URL(string: link) {
                Button { openURL(url) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open on GitHub")
            }
            if !entry.isDirectory && TextFileEditor.canEdit(entry.name) {
                Button {
                    open(entry)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit this file in LifeTracker")
            }
            if !entry.isDirectory {
                Button {
                    downloadFile(entry)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(downloadName != nil)
                .help("Download this file")
                Button(role: .destructive) {
                    deletingEntry = entry
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this file from the repo")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .contentShape(Rectangle())
        .onTapGesture {
            guard entry.isDirectory else { return }
            path = entry.path
            Task { await loadFiles() }
        }
    }

    // MARK: Bits and pieces

    private func heading(_ text: String) -> some View {
        Text(text.lowercased())
            .font(.mono(14, .bold))
            .italic()
            .foregroundStyle(Palette.accent)
    }

    @ViewBuilder
    private var status: some View {
        if let name = downloadName {
            HStack(spacing: 10) {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                    .tint(Palette.accent)
                Text(name).font(.mono(10)).lineLimit(1).frame(maxWidth: 180)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Palette.callout, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .padding(.bottom, 8)
        } else if let toast {
            Text(toast)
                .font(.mono(12))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Palette.callout, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline))
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// True when the repo already has a readme at the level we're looking at.
    private var hasReadme: Bool {
        entries.contains { $0.name.lowercased().hasPrefix("readme") && !$0.isDirectory }
    }

    private func openReadme() {
        let name = entries.first { $0.name.lowercased().hasPrefix("readme") && !$0.isDirectory }?.path
        let target = name ?? (path.isEmpty ? "README.md" : "\(path)/README.md")
        Task { @MainActor in
            var file = await hub.readTextFile(at: target, in: repo)
            if file.text.isEmpty && file.sha == nil {
                file.text = TextFileEditor.starter(for: repo)
            }
            editingFile = EditableFile(file: file)
        }
    }

    private func open(_ entry: GitHubEntry) {
        Task { @MainActor in
            editingFile = EditableFile(file: await hub.readTextFile(at: entry.path, in: repo))
        }
    }

    @MainActor
    private func loadFiles() async {
        loadingFiles = true
        entries = await hub.contents(of: repo, path: path)
        loadingFiles = false
    }

    @MainActor
    private func loadReleases() async {
        loadingReleases = true
        releases = await hub.releases(for: repo)
        loadingReleases = false
    }

    private func downloadFile(_ entry: GitHubEntry) {
        downloadName = entry.name
        downloadProgress = 0
        Task { @MainActor in
            do {
                let url = try await hub.download(entry, in: repo) { fraction in
                    downloadProgress = fraction
                }
                downloadName = nil
                keep(url, named: entry.name)
            } catch {
                downloadName = nil
                show(error.localizedDescription)
            }
        }
    }

    private func downloadAsset(_ asset: GitHubRelease.Asset) {
        downloadName = asset.name
        downloadProgress = 0
        Task { @MainActor in
            do {
                let url = try await hub.download(asset: asset, in: repo) { fraction in
                    downloadProgress = fraction
                }
                downloadName = nil
                keep(url, named: asset.name)
            } catch {
                downloadName = nil
                show(error.localizedDescription)
            }
        }
    }

    /// Mac: asks where to put it. iPad: hands it to the share sheet, so you can
    /// Save to Files, AirDrop it, or open it in another app.
    @MainActor
    private func keep(_ url: URL, named name: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let destination = panel.url {
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                show("Saved \(destination.lastPathComponent)")
            } catch {
                show("Couldn't save it: \(error.localizedDescription)")
            }
        }
        #else
        ShareTools.share([url])
        show("Downloaded \(name)")
        #endif
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { toast = nil }
        }
    }
}

// MARK: - A repository, open on its own page

private struct RepoDetailView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutWidth) private var width
    @ObservedObject private var hub = GitHubSync.shared

    let repo: GitHubRepo

    @State private var readme = ""
    @State private var loadingReadme = false
    @State private var showReadme = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if showReadme && !readme.isEmpty {
                    Text(readme)
                        .font(.mono(11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
                }
                RepoBrowser(repo: repo)
            }
            .padding(AppLayout.pagePadding(width))
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
        .navigationTitle(repo.name)
        .blendedToolbar()
        .task(id: repo.id) { await loadReadme() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book")
                    .foregroundStyle(repo.isPrivate ? StudyPalette.brown : Palette.mutedText)
                Text(repo.full_name).font(.mono(17, .bold)).lineLimit(1)
                Spacer(minLength: 6)
                if loadingReadme { ProgressView().controlSize(.small) }
                if !readme.isEmpty {
                    Button {
                        withAnimation { showReadme.toggle() }
                    } label: {
                        Label(showReadme ? "Hide README" : "README", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    if let url = URL(string: repo.html_url) { openURL(url) }
                } label: {
                    Label("github.com", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let description = repo.description, !description.isEmpty {
                Text(description).font(.mono(12)).foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(repo.branch)
                    .font(.mono(10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.subtleFill, in: Capsule())
                if let size = repo.size, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size) * 1024, countStyle: .file))
                        .font(.mono(10)).foregroundStyle(Palette.mutedText)
                }
                Spacer()
            }
        }
    }

    @MainActor
    private func loadReadme() async {
        loadingReadme = true
        defer { loadingReadme = false }
        let root = await hub.contents(of: repo, path: "")
        guard let file = root.first(where: { $0.name.lowercased().hasPrefix("readme") }) else {
            readme = ""
            return
        }
        do {
            let url = try await hub.download(file, in: repo) { _ in }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            readme = String(text.prefix(20_000))
        } catch {
            readme = ""
        }
    }
}

// MARK: - Profile (green dots and all)

private struct GitHubProfileView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutWidth) private var width
    @ObservedObject private var hub = GitHubSync.shared

    @State private var year = ContributionYear()
    @State private var loading = false
    @State private var editing = false
    @State private var focusedDay: ContributionDay?
    @State private var changingAvatar = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card
                contributions
                stats
            }
            .padding(AppLayout.pagePadding(width))
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
        .navigationTitle("Profile")
        .blendedToolbar()
        .task { await load() }
        .sheet(isPresented: $editing) {
            EditProfileSheet()
        }
        .sheet(isPresented: $changingAvatar, onDismiss: {
            // Pull the new avatar URL once you're done on GitHub's page.
            Task { @MainActor in await hub.refresh() }
        }) {
            GitHubWebSheet(title: "Profile picture",
                           url: "https://github.com/settings/profile",
                           note: "GitHub has no API for avatars, so this is their own page, opened inside LifeTracker. Sign in if it asks, set the picture, then close.")
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                changingAvatar = true
            } label: {
                GitHubAvatar(url: hub.user?.avatar_url, size: 86)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.onAccent)
                            .padding(5)
                            .background(Palette.accent, in: Circle())
                            .offset(x: 4, y: 4)
                    }
            }
            .buttonStyle(.plain)
            .help("Change your profile picture")
            VStack(alignment: .leading, spacing: 5) {
                Text(hub.user?.displayName ?? "").font(.mono(20, .bold))
                Text("@\(hub.user?.login ?? "")")
                    .font(.mono(12)).foregroundStyle(Palette.mutedText)
                if let bio = hub.user?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.mono(12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                HStack(spacing: 12) {
                    if let company = hub.user?.company, !company.isEmpty {
                        Label(company, systemImage: "building.2").font(.mono(10))
                    }
                    if let location = hub.user?.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse").font(.mono(10))
                    }
                }
                .foregroundStyle(Palette.mutedText)
                if let blog = hub.user?.blog, !blog.isEmpty {
                    Button {
                        if let url = LinkTools.normalize(blog) { openURL(url) }
                    } label: {
                        Label(blog, systemImage: "link").font(.mono(10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                }
                HStack(spacing: 8) {
                    Button { editing = true } label: {
                        Label("Edit profile", systemImage: "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudyPalette.brown)
                    .controlSize(.small)
                    Button {
                        if let url = URL(string: hub.user?.html_url ?? "https://github.com") { openURL(url) }
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StudyPalette.line))
    }

    private var contributions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("contributions")
                    .font(.mono(14, .bold)).italic()
                    .foregroundStyle(Palette.accent)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Text("\(year.total) in the last year")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .help("Ask GitHub again — the graph can take a minute to catch up after a push")
            }

            if year.weeks.isEmpty && !loading {
                Text("No contribution data. GitHub only shares this through its GraphQL API, which needs the read:user scope on your token — make a new one from the ⋯ menu if yours is older.")
                    .font(.mono(11)).foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Reads out the day under the pointer (or the one you tapped),
                // so the counts aren't hidden inside a tooltip.
                dayReadout

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(Array(year.weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 3) {
                                ForEach(week) { day in
                                    square(day)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack(spacing: 6) {
                    Text("Less").font(.mono(9)).foregroundStyle(Palette.mutedText)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(level == 0 ? Palette.subtleFill : Self.greens[level - 1])
                            .frame(width: 10, height: 10)
                    }
                    Text("More").font(.mono(9)).foregroundStyle(Palette.mutedText)
                    Spacer()
                    if year.currentStreak > 0 {
                        Text("\(year.currentStreak)-day streak")
                            .font(.mono(10, .semibold)).foregroundStyle(Palette.accent)
                    }
                }
            }
        }
        .padding(16)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StudyPalette.line))
    }

    private func square(_ day: ContributionDay) -> some View {
        let isFocused = focusedDay?.date == day.date
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color(for: day.count))
            .frame(width: 11, height: 11)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: isFocused ? 1.5 : 0)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { focusedDay = day }
                else if focusedDay?.date == day.date { focusedDay = nil }
            }
            .onTapGesture { focusedDay = day }
            .help("\(day.count) contribution\(day.count == 1 ? "" : "s") on \(day.date.formatted(date: .abbreviated, time: .omitted))")
    }

    /// One line showing the day you're pointing at — the count is the whole
    /// point of the graph, so it shouldn't need a tooltip to appear.
    private var dayReadout: some View {
        let day = focusedDay
        return HStack(spacing: 8) {
            if let day {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: day.count))
                    .frame(width: 11, height: 11)
                Text("\(day.count) contribution\(day.count == 1 ? "" : "s")")
                    .font(.mono(12, .semibold))
                    .foregroundStyle(day.count > 0 ? Palette.accent : Palette.mutedText)
                Text("on \(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))")
                    .font(.mono(11))
                    .foregroundStyle(Palette.mutedText)
            } else {
                Text(Platform.isMac
                     ? "Point at a square to see that day's count"
                     : "Tap a square to see that day's count")
                    .font(.mono(11))
                    .foregroundStyle(Palette.mutedText)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: focusedDay?.date)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            statTile("Repositories", hub.user?.public_repos ?? hub.repos.count, "book.closed")
            statTile("Followers", hub.user?.followers ?? 0, "person.2")
            statTile("Following", hub.user?.following ?? 0, "person.badge.plus")
            statTile("Busiest day", year.busiestDay, "flame")
        }
    }

    private func statTile(_ title: String, _ value: Int, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.mono(10))
                .foregroundStyle(Palette.mutedText)
            Text("\(value)")
                .font(.mono(20, .bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(StudyPalette.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudyPalette.line))
    }

    private static let greens = [Color(hex: "9BE9A8"), Color(hex: "40C463"),
                                 Color(hex: "30A14E"), Color(hex: "216E39")]

    private func color(for count: Int) -> Color {
        guard count > 0 else { return Palette.subtleFill }
        let step = max(1, year.busiestDay / 4)
        return Self.greens[min(3, (count - 1) / step)]
    }

    @MainActor
    private func load() async {
        loading = true
        await hub.refresh()
        year = await hub.contributions(for: hub.user?.login ?? "")
        loading = false
    }
}

// MARK: - Edit profile

private struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var hub = GitHubSync.shared

    @State private var name = ""
    @State private var bio = ""
    @State private var company = ""
    @State private var location = ""
    @State private var blog = ""
    @State private var busy = false
    @State private var error: String?
    @State private var changingAvatar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit GitHub profile").font(.mono(16, .bold))
            Text("Saved straight to github.com. Your token needs the user scope.")
                .font(.mono(11)).foregroundStyle(Palette.mutedText)

            FormTextField("Name", text: $name)

            VStack(alignment: .leading, spacing: 5) {
                Text("BIO").font(.mono(10, .semibold)).foregroundStyle(Palette.mutedText)
                TextEditor(text: $bio)
                    .font(.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 80)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
                Text("\(bio.count)/160")
                    .font(.mono(9))
                    .foregroundStyle(bio.count > 160 ? Color(hex: "C0453F") : Palette.mutedText)
            }

            Group {
                FormTextField("Company", text: $company)
                FormTextField("Location", text: $location)
                FormTextField("Website", text: $blog)
            }

            HStack(spacing: 10) {
                GitHubAvatar(url: hub.user?.avatar_url, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profile picture").font(.mono(11, .semibold))
                    Text("GitHub has no API for avatars, so this opens their page inside the app.")
                        .font(.mono(10)).foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button("Change…") { changingAvatar = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .background(Palette.callout, in: RoundedRectangle(cornerRadius: 10))

            if let error {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || bio.count > 160)
            }
        }
        .padding(20)
        .sheetFrame(width: 500, height: 560)
        .sheet(isPresented: $changingAvatar, onDismiss: {
            Task { @MainActor in await hub.refresh() }
        }) {
            GitHubWebSheet(title: "Profile picture",
                           url: "https://github.com/settings/profile",
                           note: "GitHub has no API for avatars, so this is their own page, opened inside LifeTracker. Sign in if it asks, set the picture, then close.")
        }
        .onAppear {
            name = hub.user?.name ?? ""
            bio = hub.user?.bio ?? ""
            company = hub.user?.company ?? ""
            location = hub.user?.location ?? ""
            blog = hub.user?.blog ?? ""
        }
    }

    private func save() {
        busy = true
        error = nil
        Task { @MainActor in
            if await hub.updateProfile(name: name, bio: bio, company: company,
                                       location: location, blog: blog) {
                dismiss()
            } else {
                error = hub.lastError ?? "GitHub wouldn't save that."
            }
            busy = false
        }
    }
}

// MARK: - Avatar

private struct GitHubAvatar: View {
    let url: String?
    var size: CGFloat = 42

    var body: some View {
        Group {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .strokeBorder(Palette.hairline))
    }

    private var placeholder: some View {
        ZStack {
            Color(hex: "24292F")
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.white)
        }
    }
}


// MARK: - GitHub's own page, inside the app

/// Some things GitHub simply has no API for — the avatar is the one that
/// matters here. Rather than throwing you out to Safari, this puts github.com
/// in a web view inside LifeTracker, with its own cookie store so the sign-in
/// sticks between visits.
private struct GitHubWebSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let url: String
    var note: String = ""

    @StateObject private var model = SimpleWeb()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                Text(model.pageTitle.isEmpty ? title : model.pageTitle)
                    .font(.mono(12, .semibold))
                    .lineLimit(1)
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.sidebar)

            if !note.isEmpty {
                Text(note)
                    .font(.mono(10))
                    .foregroundStyle(Palette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
                    .background(Palette.sidebar)
            }
            Divider().overlay(Palette.hairline)
            SimpleWebView(model: model)
        }
        .sheetFrame(width: 880, height: 640)
        .onAppear { model.load(url) }
    }
}

/// A plain web view with a persistent cookie store — enough for GitHub's
/// settings pages, nothing more.
private final class SimpleWeb: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var isLoading = false
    @Published var pageTitle = ""

    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.pageTitle = view.title ?? "" }
            },
        ]
    }

    func load(_ string: String) {
        guard webView.url == nil, let url = URL(string: string) else { return }
        webView.load(URLRequest(url: url))
    }
    func reload() { webView.reload() }
    func back() { webView.goBack() }

    /// GitHub opens a few things in new tabs; keep them in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url != nil { webView.load(navigationAction.request) }
        return nil
    }

    /// macOS only: a web page's "choose a file" button does nothing unless the
    /// app puts up the open panel itself. This is what makes GitHub's
    /// "Upload a photo…" (and any other file input) work.
    #if os(macOS)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    #endif

}

private struct SimpleWebView {
    @ObservedObject var model: SimpleWeb

    fileprivate func install(into container: PlatformView) {
        let web = model.webView
        if web.superview === container { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

#if os(macOS)
extension SimpleWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        install(into: container)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) { install(into: nsView) }
}
#else
extension SimpleWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        install(into: container)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) { install(into: uiView) }
}
#endif

// MARK: - Editing a text file in the repo (README and friends)

/// `.sheet(item:)` needs something Identifiable; GitHubTextFile is a plain
/// value, so it travels in this.
private struct EditableFile: Identifiable {
    let id = UUID()
    let file: GitHubTextFile
}

private struct TextFileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = GitHubSync.shared

    let repo: GitHubRepo
    let file: GitHubTextFile
    var onFinish: (Bool) -> Void

    @State private var text = ""
    @State private var message = ""
    @State private var busy = false
    @State private var error: String?
    @State private var previewing = false

    private var isNew: Bool { file.sha == nil }
    private var isReadme: Bool { (file.path as NSString).lastPathComponent.lowercased().hasPrefix("readme") }

    /// The kinds of file worth editing on a phone-sized keyboard.
    static func canEdit(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return name.lowercased().hasPrefix("readme") || name.lowercased() == "license" }
        return ["md", "markdown", "txt", "text", "json", "yml", "yaml", "toml", "ini",
                "cfg", "conf", "gitignore", "env", "csv", "html", "css", "js", "ts",
                "py", "swift", "c", "h", "cpp", "java", "kt", "sh", "rb", "go", "rs"].contains(ext)
    }

    /// A first README worth keeping, rather than an empty box.
    static func starter(for repo: GitHubRepo) -> String {
        var lines = ["# \(repo.name)", ""]
        if let description = repo.description, !description.isEmpty {
            lines += [description, ""]
        } else {
            lines += ["One line about what this does.", ""]
        }
        lines += ["## Getting started", "",
                  "1. Step one", "2. Step two", "",
                  "## Notes", "",
                  "- Anything worth remembering later"]
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isNew ? "Add \((file.path as NSString).lastPathComponent)"
                           : "Edit \((file.path as NSString).lastPathComponent)")
                    .font(.mono(16, .bold))
                Text(repo.full_name)
                    .font(.mono(10)).foregroundStyle(Palette.mutedText)
                Spacer()
                if isReadme {
                    Picker("", selection: $previewing) {
                        Text("Write").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if previewing {
                ScrollView {
                    Text(markdown)
                        .font(.mono(12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            HStack(spacing: 8) {
                Text("\(text.count) characters · \(text.split(whereSeparator: \.isNewline).count) lines")
                    .font(.mono(10)).foregroundStyle(Palette.mutedText)
                Spacer()
                if isReadme && !previewing {
                    Button("Heading") { insert("\n## ") }
                    Button("List") { insert("\n- ") }
                    Button("Code") { insert("\n```\n\n```\n") }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            TextField(isNew ? "Commit message (optional)" : "What changed? (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .font(.mono(11))

            if let error {
                Text(error)
                    .font(.mono(11)).foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onFinish(false); dismiss() }
                    .disabled(busy)
                Button(isNew ? "Create" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "2DA44E"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .sheetFrame(width: 640, height: 620)
        .onAppear { text = file.text }
    }

    /// Markdown for the preview tab. Falls back to the raw text if it can't be
    /// parsed, so nothing is ever lost behind a rendering error.
    private var markdown: AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func insert(_ snippet: String) {
        text += snippet
    }

    private func save() {
        busy = true
        error = nil
        var updated = file
        updated.text = text
        Task { @MainActor in
            let commit = message.isEmpty
                ? (isNew ? "Add \((file.path as NSString).lastPathComponent) from LifeTracker" : "Update \((file.path as NSString).lastPathComponent)")
                : message
            if await hub.saveTextFile(updated, in: repo, message: commit) {
                onFinish(true)
                dismiss()
            } else {
                error = hub.lastError ?? "GitHub wouldn't save that."
            }
            busy = false
        }
    }
}
