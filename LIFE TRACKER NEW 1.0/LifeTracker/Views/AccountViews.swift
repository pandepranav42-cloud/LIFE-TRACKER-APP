import SwiftUI
import SwiftData
import AuthenticationServices
import EventKit

// MARK: - Accounts (Settings → Accounts)

/// Current login, sign out, and the Google connection used for Drive backup
/// and Google Calendar. Used inside the Settings form.
struct AccountsSection: View {
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var drive = DriveSync.shared
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.modelContext) private var context
    @State private var connectingGoogle = false
    @State private var confirmSignOut = false
    @State private var showGoogleSetup = false
    @AppStorage("googleClientID") private var clientID: String = ""

    var body: some View {
        Section {
            if let session = accounts.session {
                HStack(spacing: 12) {
                    Image(systemName: session.icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 36, height: 36)
                        .background(Palette.callout, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).font(.system(size: 14, weight: .semibold))
                        Text("Signed in with \(session.methodTitle)" + (session.email.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(Palette.mutedText)
                    }
                    Spacer()
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Account")
        }
        .confirmationDialog("Sign out of LifeTracker?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { accounts.signOutEverywhere() }
        } message: {
            Text("Your data stays on this device. You'll be taken back to the login screen.")
        }

        Section {
            // Google connection (for Drive + Calendar)
            if accounts.isGoogleSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 17))
                        .frame(width: 36, height: 36)
                        .background(Palette.callout, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accounts.googleEmail ?? "Google account").font(.system(size: 14, weight: .medium))
                        Text(accounts.hasDriveScope ? "Drive + Calendar connected" : "Calendar only — reconnect to allow Drive")
                            .font(.caption).foregroundStyle(Palette.mutedText)
                    }
                    Spacer()
                    if !accounts.hasDriveScope { connectGoogleButton(title: "Reconnect") }
                    if accounts.session?.method != .google {
                        Button("Disconnect") { accounts.signOutGoogle() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Drive & Calendar").font(.system(size: 14, weight: .medium))
                        Text("Connect Google to back up your files and sync your calendar.")
                            .font(.caption).foregroundStyle(Palette.mutedText)
                    }
                    Spacer()
                    if AppConfig.isGoogleConfigured {
                        connectGoogleButton(title: "Connect Google")
                    } else {
                        Button("Set up…") { showGoogleSetup = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                if !AppConfig.isGoogleConfigured {
                    Label("Google needs a free client ID for this app before it can sign you in. One-time setup, about 3 minutes.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $drive.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Back up files to Google Drive")
                    Text("PDFs, slides, documents and pictures you add are copied to a “LifeTracker” folder in your Drive.")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                }
            }
            .disabled(!accounts.isGoogleSignedIn)

            if accounts.isGoogleSignedIn && drive.enabled {
                HStack {
                    Button {
                        Task { await drive.backupAll(context: context) }
                    } label: {
                        Label("Back up everything now", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(drive.isUploading || !accounts.hasDriveScope)
                    Spacer()
                    if drive.isUploading { ProgressView().controlSize(.small) }
                }
                if !drive.status.isEmpty {
                    Text(drive.status).font(.caption).foregroundStyle(Palette.mutedText)
                }
            }

            if let error = accounts.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connected services")
        } footer: {
            Text("Deleting a file in LifeTracker keeps its copy in Drive, so Drive stays a safe backup. LifeTracker can only see files it created in your Drive.")
                .font(.caption).foregroundStyle(Palette.mutedText)
        }
        .sheet(isPresented: $showGoogleSetup) { googleSetupSheet() }
    }

    private func googleSetupSheet() -> some View {
        GoogleSetupSheet(clientID: $clientID)
    }

    private func connectGoogleButton(title: String) -> some View {
        Button {
            connectingGoogle = true
            Task {
                await accounts.signInWithGoogle(using: webAuth)
                connectingGoogle = false
            }
        } label: {
            if connectingGoogle { ProgressView().controlSize(.small) } else { Text(title) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(connectingGoogle)
    }
}

// MARK: - Calendar sync sheet (Calendar page → Sync)

struct CalendarSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @ObservedObject private var sync = CalendarSync.shared
    @ObservedObject private var accounts = AccountStore.shared
    let marks: [CalendarMark]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Calendar Sync").font(.mono(16, .bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { sync.appleEnabled },
                        set: { on in
                            sync.appleEnabled = on
                            if on { Task { await sync.requestAppleAccess() } }
                        })) {
                        Label("Apple Calendar", systemImage: "calendar")
                    }
                    if sync.appleEnabled {
                        if sync.hasAppleAccess {
                            Picker("Add events to", selection: $sync.appleCalendarID) {
                                Text("“LifeTracker” calendar (created for you)").tag("")
                                ForEach(sync.writableCalendars, id: \.calendarIdentifier) { cal in
                                    Text("\(cal.title) — \(cal.source.title)").tag(cal.calendarIdentifier)
                                }
                            }
                        } else {
                            Button("Allow calendar access") { Task { await sync.requestAppleAccess() } }
                        }
                    }
                } header: {
                    Text("Apple Calendar")
                } footer: {
                    Text("Anything you mark on the LifeTracker calendar is added to Apple Calendar, and edits and deletes follow. If your Google account is added in System Settings → Internet Accounts, you can pick one of its calendars here too. Events already in Apple Calendar show on the LifeTracker calendar.")
                }

                Section {
                    Toggle(isOn: $sync.googleEnabled) {
                        Label("Google Calendar", systemImage: "g.circle")
                    }
                    .disabled(!accounts.isGoogleSignedIn)
                    if !accounts.isGoogleSignedIn {
                        Text("Connect Google in Settings → Connected services to turn this on.")
                            .font(.caption).foregroundStyle(Palette.mutedText)
                    } else if let email = accounts.googleEmail {
                        LabeledContent("Account", value: email)
                    }
                } header: {
                    Text("Google Calendar")
                } footer: {
                    Text("Adds your marks to the primary calendar of the signed-in Google account.")
                }

                Section {
                    Button {
                        Task {
                            await sync.syncAll(marks)
                            try? context.save()
                        }
                    } label: {
                        HStack {
                            Text("Sync everything now")
                            Spacer()
                            if sync.isSyncing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(sync.isSyncing || !(sync.appleEnabled || sync.googleEnabled))
                    if !sync.status.isEmpty {
                        Text(sync.status).font(.caption).foregroundStyle(Palette.mutedText)
                    }
                }
            }
            .themedForm()
        }
        .sheetFrame(width: 520, height: 560)
    }
}


// MARK: - Google setup (one-time client ID)

/// Google requires every app to have its own free "OAuth client ID" before it
/// will show a sign-in page. This sheet walks through getting one and stores it.
struct GoogleSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var clientID: String
    @State private var draft = ""

    private var isValid: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".apps.googleusercontent.com")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connect Google").font(.mono(16, .bold))
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider().overlay(Palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Google only lets an app sign you in if the app has its own ID. It's free, and you only do this once.")
                        .font(.subheadline).foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    step(1, "Open Google Cloud Console and create a project",
                         "Any name works — for example “LifeTracker”.")
                    Button("Open Google Cloud Console") {
                        openURL(URL(string: "https://console.cloud.google.com/projectcreate")!)
                    }
                    .buttonStyle(.bordered)

                    step(2, "Turn on the two APIs the app uses",
                         "APIs & Services → Library → enable “Google Drive API” and “Google Calendar API”.")
                    step(3, "Fill in the OAuth consent screen",
                         "Choose External, add an app name and your email, then add your own Gmail address under Test users.")
                    step(4, "Create the client ID",
                         "Credentials → Create credentials → OAuth client ID → Application type: iOS → Bundle ID: com.pranavpande.LifeTracker (this also works for the Mac app).")
                    step(5, "Paste it below", "It looks like 1234567890-abc123.apps.googleusercontent.com")

                    TextField("…apps.googleusercontent.com", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.mono(12))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    HStack {
                        Button("Paste") {
                            if let s = Platform.pastedString() { draft = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Save and continue") {
                            clientID = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid)
                    }
                    if !draft.isEmpty && !isValid {
                        Text("That doesn't look right — the ID ends in .apps.googleusercontent.com")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("Prefer to put it in the code instead? Set AppConfig.googleClientID in Models/Accounts.swift.")
                        .font(.caption2).foregroundStyle(Palette.mutedText)
                }
                .padding(20)
            }
        }
        .sheetFrame(width: 560, height: 620)
        .onAppear { draft = clientID }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.mono(12, .bold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 22, height: 22)
                .background(Palette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


// MARK: - Backup & transfer (Settings → move everything to another device)

struct TransferSection: View {
    @Environment(\.modelContext) private var context
    @State private var status = ""
    @State private var busy = false
    @State private var importing = false
    @State private var exportedURL: URL?
    @State private var pending: PendingImport?
    @State private var error: String?
    @AppStorage("transfer.includeLogins") private var includeLogins = true

    struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
        let manifest: Transfer.Manifest
    }

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export everything").font(.system(size: 14, weight: .medium))
                    Text("One file with your habits, schedule, timetable picture, calendar, journal, subjects, notes, links and every uploaded file.")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    exportNow()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Export…") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busy)
            }

            Toggle(isOn: $includeLogins) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include saved logins").font(.system(size: 14, weight: .medium))
                    Text("Your GitHub token and every saved portal ID and password travel with the file, so the other device is ready to use straight away. Turn this off before sending the file to anyone else — whoever opens it can sign in as you.")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import a backup").font(.system(size: 14, weight: .medium))
                    Text("Open a .lifetracker file from another device. Everything here is replaced by what's in the file, so both devices end up identical.")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Import…") { importing = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(Palette.mutedText)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if !os(macOS)
            if let exportedURL {
                ShareLink(item: exportedURL) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                }
            }
            #endif
        } header: {
            Text("Backup & transfer")
        } footer: {
            Text("Mac and iPad keep their own copies, so changes on one don't appear on the other by themselves — export when you want to carry everything across.")
                .font(.caption).foregroundStyle(Palette.mutedText)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            do {
                // Copy somewhere we can keep reading from while importing.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                if access { url.stopAccessingSecurityScopedResource() }
                pending = PendingImport(url: copy, manifest: try Transfer.readManifest(at: copy))
                error = nil
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                self.error = error.localizedDescription
            }
        }
        .sheet(item: $pending) { item in
            ImportSheet(url: item.url, manifest: item.manifest) { summary in
                status = summary
            }
        }
    }

    private func exportNow() {
        busy = true
        status = "Packing…"
        error = nil
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(Transfer.suggestedFileName())
        do {
            try? FileManager.default.removeItem(at: temp)
            try Transfer.export(context: context, to: temp, includeLogins: includeLogins) { status = $0 }
            let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let pretty = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = temp.lastPathComponent
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let dest = panel.url {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                status = "Saved \(pretty) to \(dest.lastPathComponent)"
            } else {
                status = ""
            }
            #else
            exportedURL = temp
            status = "Ready (\(pretty)) — tap Share / Save to Files"
            #endif
        } catch {
            self.error = error.localizedDescription
            status = ""
        }
        busy = false
    }
}

private struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let url: URL
    let manifest: Transfer.Manifest
    var onFinish: (String) -> Void

    @State private var busy = false
    @State private var step = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import backup").font(.mono(16, .bold))
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
            }
            .padding()
            Divider().overlay(Palette.hairline)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(manifest.summary).font(.system(size: 14, weight: .medium))
                    Text("From \(manifest.deviceName) · \(manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Palette.mutedText)
                    if manifest.secrets?.isEmpty == false {
                        Label("Includes saved logins — your GitHub token and portal IDs come across too.",
                              systemImage: "key.fill")
                            .font(.caption).foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.callout, in: RoundedRectangle(cornerRadius: 10))

                Label("Everything on this device is replaced with what's in this file, so both devices end up identical. Anything here that isn't in the file is deleted.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(hex: "C0453F"))
                    .fixedSize(horizontal: false, vertical: true)

                if busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(step).font(.caption).foregroundStyle(Palette.mutedText)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Replace everything with this") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .sheetFrame(width: 460, height: 380)
    }

    private func run() {
        busy = true
        error = nil
        Task { @MainActor in
            do {
                // The marks about to be wiped must leave the calendars first,
                // otherwise their events are orphaned there.
                step = "Clearing old calendar events…"
                let marks = (try? context.fetch(FetchDescriptor<CalendarMark>())) ?? []
                await CalendarSync.shared.removeEverything(marks)
                let result = try Transfer.importArchive(at: url, context: context) { step = $0 }
                // Logins that came across should take effect straight away.
                if result.secrets?["github.token"] != nil {
                    step = "Signing in to GitHub…"
                    await GitHubSync.shared.refresh()
                }
                onFinish("Imported \(result.summary) from \(result.deviceName)")
                busy = false
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
