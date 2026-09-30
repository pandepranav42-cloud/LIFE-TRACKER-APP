import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Life AI, floating over every page
//
// One overlay lives above the whole app, so the logo and the chat follow you
// everywhere — Today, Study, a subject, JUNO, the GitHub console. Nothing here
// is tied to a page.
//
// The logo can be dragged anywhere and stays where you put it. ⌘⇧L opens and
// closes the chat on the Mac.

struct LifeAIOverlay: ViewModifier {
    @ObservedObject private var ai = LifeAI.shared
    @ObservedObject private var bridge = LifeAIBridge.shared
    @State private var isOpen = false

    // Where the floating logo sits, as a fraction of the window so it stays
    // put when the window is resized. -1 means "not moved yet".
    @AppStorage("lifeAI.orbX") private var orbX: Double = -1
    @AppStorage("lifeAI.orbY") private var orbY: Double = -1
    @State private var drag: CGSize = .zero
    @State private var didDrag = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            GeometryReader { geo in
                let size = geo.size
                let orbSize: CGFloat = 58
                let inset: CGFloat = 20
                let home = CGPoint(x: size.width - orbSize / 2 - inset,
                                   y: size.height - orbSize / 2 - inset)
                let saved = CGPoint(x: orbX < 0 ? home.x : orbX * size.width,
                                    y: orbY < 0 ? home.y : orbY * size.height)
                let position = CGPoint(
                    x: min(max(saved.x + drag.width, orbSize / 2 + 8), max(size.width - orbSize / 2 - 8, orbSize)),
                    y: min(max(saved.y + drag.height, orbSize / 2 + 8), max(size.height - orbSize / 2 - 8, orbSize))
                )

                ZStack(alignment: .topLeading) {
                    if isOpen {
                        LifeAIPanel(isOpen: $isOpen)
                            .frame(width: panelWidth(size), height: panelHeight(size))
                            .position(panelCenter(anchor: position, size: size))
                            .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
                    }

                    LifeAIOrb(isOpen: isOpen, isBusy: ai.isStreaming)
                        .frame(width: orbSize, height: orbSize)
                        .position(position)
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    didDrag = true
                                    drag = value.translation
                                }
                                .onEnded { _ in
                                    orbX = min(max(position.x / max(size.width, 1), 0), 1)
                                    orbY = min(max(position.y / max(size.height, 1), 0), 1)
                                    drag = .zero
                                    // Let the tap handler know this was a move.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { didDrag = false }
                                }
                        )
                        .onTapGesture {
                            guard !didDrag else { return }
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { isOpen.toggle() }
                        }
                }
                .frame(width: size.width, height: size.height)
            }
            .ignoresSafeArea(.keyboard)
        }
        // Another page asked Life AI something — open up so the panel can take it.
        .onReceive(bridge.$pending) { request in
            guard request != nil, !isOpen else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { isOpen = true }
        }
        .background {
            // Invisible key equivalent: ⌘⇧L anywhere in the app.
            Button("Life AI") {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { isOpen.toggle() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func panelWidth(_ size: CGSize) -> CGFloat {
        min(max(size.width - 40, 280), 470)
    }
    private func panelHeight(_ size: CGSize) -> CGFloat {
        min(max(size.height - 120, 320), 680)
    }

    /// Keeps the panel beside the logo, but always fully on screen.
    private func panelCenter(anchor: CGPoint, size: CGSize) -> CGPoint {
        let width = panelWidth(size), height = panelHeight(size)
        let preferTop = anchor.y > size.height / 2
        var x = anchor.x - width / 2 + 10
        var y = preferTop ? anchor.y - height / 2 - 44 : anchor.y + height / 2 + 44
        x = min(max(x, width / 2 + 12), max(size.width - width / 2 - 12, width / 2 + 12))
        y = min(max(y, height / 2 + 12), max(size.height - height / 2 - 12, height / 2 + 12))
        return CGPoint(x: x, y: y)
    }
}

extension View {
    /// Puts Life AI on top of everything. Applied once, in RootView.
    func lifeAIOverlay() -> some View { modifier(LifeAIOverlay()) }
}

// MARK: - The floating logo

struct LifeAIOrb: View {
    var isOpen: Bool
    var isBusy: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Palette.elevated)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)

            Image("LifeAILogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(isBusy ? Palette.accent : Palette.hairline, lineWidth: isBusy ? 2 : 1)

            if isOpen {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .scaleEffect(isBusy && pulse ? 1.06 : 1)
        .animation(isBusy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
        .onAppear { pulse = true }
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .help(isOpen ? "Close Life AI" : "Life AI  (⌘⇧L)  — drag to move")
        .accessibilityLabel("Life AI")
    }
}

// MARK: - The panel

struct LifeAIPanel: View {
    @Binding var isOpen: Bool
    @Environment(\.modelContext) private var context
    @ObservedObject private var ai = LifeAI.shared
    @ObservedObject private var index = AIIndex.shared
    @ObservedObject private var bridge = LifeAIBridge.shared
    @ObservedObject private var github = GitHubSync.shared
    @ObservedObject private var listener = SpeechListener.shared
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var voiceChat = VoiceChat.shared
    @ObservedObject private var voice = VoiceSettings.shared

    @Query(sort: \AIConversation.updatedAt, order: .reverse) private var conversations: [AIConversation]

    @State private var chat: AIConversation?
    @State private var draft = ""
    @State private var attachments: [AIAttachment] = []
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var showingKeySheet = false
    @FocusState private var composerFocused: Bool

    /// A label like "Google Gemini" — the custom endpoint uses your own name.
    static func providerLabel(_ provider: AIProvider) -> String {
        provider == .custom ? "\(AIProviderStore.customName) (OpenAI-compatible)" : provider.title
    }

    private var messages: [AIMessage] { chat?.ordered ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairline)
            transcript
            Divider().overlay(Palette.hairline)
            composer
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(dropTargeted ? Palette.accent : Palette.hairline, lineWidth: dropTargeted ? 2 : 1))
        .shadow(color: .black.opacity(0.22), radius: 26, y: 10)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            attach(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .sheet(isPresented: $showingKeySheet) { LifeAIKeySheet() }
        .task {
            if chat == nil { chat = conversations.first }
            // Speaking into the panel goes through the same send path as typing.
            VoiceChat.shared.onUtterance = { heard in send(heard, spoken: true) }
            await ai.loadModelsIfNeeded()
            takePendingRequest()
            await index.refresh(context: context)
        }
        // Plain dictation types into the composer as you speak; voice chat
        // sends by itself, so it doesn't touch the field.
        .onChange(of: listener.transcript) { _, heard in
            guard listener.isListening, !voiceChat.isActive else { return }
            draft = heard
        }
        .onDisappear {
            listener.stop()
            VoiceChat.shared.stop()
            // The singleton would otherwise hold a stale copy of this view —
            // and with it the model context — for the life of the app.
            VoiceChat.shared.onUtterance = nil
            speaker.stop()
        }
        // @Published fires in willSet, so `bridge.pending` still holds the OLD
        // value while this runs. Hence the hop: read it once it has settled.
        // The nil guard also stops the clear inside takePendingRequest() from
        // re-entering this closure forever.
        .onReceive(bridge.$pending) { request in
            guard request != nil else { return }
            DispatchQueue.main.async { takePendingRequest() }
        }
        // A request that arrived mid-answer is held, not dropped — run it when
        // the current one finishes.
        .onChange(of: ai.isStreaming) { _, streaming in
            if !streaming { takePendingRequest() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("LifeAILogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Life AI").font(.mono(13, .bold))
                Text(subtitle)
                    .font(.mono(10))
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            headerMenu

            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { isOpen = false }
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.mutedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.callout)
    }

    private var subtitle: String {
        if voiceChat.isActive {
            if speaker.isSpeaking { return "Speaking…" }
            if listener.isListening { return "Listening…" }
            return "Voice chat on"
        }
        if listener.isListening { return "Listening…" }
        if !ai.activity.isEmpty { return ai.activity }
        if ai.isLoadingModels && ai.models.isEmpty { return "Checking which models your key can use…" }
        let model = ai.models.first(where: { $0.name == ai.modelName })?.shortTitle ?? ai.modelName
        return model.isEmpty ? ai.providerTitle : "\(ai.providerTitle) · \(model)"
    }

    private var headerMenu: some View {
        Menu {
            Menu("AI") {
                ForEach(AIProvider.allCases) { option in
                    Button {
                        ai.provider = option
                        Task { await ai.loadModelsIfNeeded() }
                    } label: {
                        if option == ai.provider {
                            Label(Self.providerLabel(option), systemImage: "checkmark")
                        } else {
                            Text(Self.providerLabel(option))
                        }
                    }
                }
                Divider()
                Button("Keys and endpoints…", systemImage: "key") { showingKeySheet = true }
            }
            Menu("Model") {
                if ai.models.isEmpty {
                    // A disabled button rather than bare Text — plain content
                    // in a Menu doesn't render reliably on iPadOS.
                    Button(ai.isLoadingModels ? "Loading…" : "Not loaded yet") {}
                        .disabled(true)
                } else {
                    ForEach(ai.models) { model in
                        Button {
                            ai.modelName = model.name
                        } label: {
                            if model.name == ai.modelName {
                                Label(model.shortTitle, systemImage: "checkmark")
                            } else {
                                Text(model.shortTitle)
                            }
                        }
                    }
                }
                Divider()
                Button("Refresh model list") { Task { _ = await ai.reloadModels() } }
            }
            // Grouped to stay inside ViewBuilder's 10-child limit.
            Group {
                Divider()
                Toggle(isOn: Binding(get: { voice.speakEveryReply },
                                     set: { voice.speakEveryReply = $0 })) {
                    Label("Read answers aloud", systemImage: "speaker.wave.2")
                }
                Divider()
                Button("Attach files…", systemImage: "paperclip") { importing = true }
                Button("New chat", systemImage: "square.and.pencil") { startNewChat() }
                if conversations.count > 1 {
                    Menu("Earlier chats") {
                        ForEach(conversations.prefix(15)) { item in
                            Button(item.title) { chat = item }
                        }
                    }
                }
            }
            Divider()
            Button(index.isIndexing ? "Indexing material…" : "Re-read my material", systemImage: "arrow.clockwise") {
                Task { await index.refresh(context: context, force: true) }
            }
            .disabled(index.isIndexing)
            if let chat, !chat.messages.isEmpty {
                Divider()
                Button("Delete this chat", systemImage: "trash", role: .destructive) {
                    context.delete(chat)
                    try? context.save()
                    self.chat = nil
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && !ai.isStreaming {
                        welcome
                    }
                    ForEach(messages) { message in
                        LifeAIBubble(message: message)
                            .id(message.id)
                    }
                    if ai.isStreaming {
                        LifeAIStreamingBubble(text: ai.partial, activity: ai.activity)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in scroll(proxy) }
            .onChange(of: ai.partial) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask me anything")
                .font(.mono(15, .bold))
            Text("Attach any document and I'll read it — PDF, Word, PowerPoint, text, code, or a photo of a page. I can also see your habits, schedule, subjects, material, calendar, progress and GitHub, and write code like any assistant. Your Journal stays private.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                importing = true
            } label: {
                Label("Attach a document to summarise", systemImage: "paperclip")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Palette.callout)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)

            StarterChips(items: Self.starters) { send($0) }

            if !ai.isConfigured {
                Button {
                    showingKeySheet = true
                } label: {
                    Label("Add a Gemini API key to begin", systemImage: "key.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 4)
    }

    private static let starters = [
        "What should I study today?",
        "Plan my week around my deadlines",
        "Summarise my GitHub activity",
        "How is my progress really going?",
        "Quiz me on my weakest subject"
    ]

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = ai.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { file in
                    attachments.removeAll { $0.id == file.id }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    importing = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach a document, PDF or picture — or just drop it on this panel")

                micButton

                TextField(attachments.isEmpty ? "Message Life AI…" : "What should I do with these?",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit { send(draft) }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Palette.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1))

                if ai.isStreaming {
                    Button {
                        ai.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(Palette.subtleFill)
                    .clipShape(Circle())
                    .help("Stop")
                } else {
                    Button {
                        send(draft)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(canSend ? Palette.accent : Palette.mutedText.opacity(0.4))
                    .clipShape(Circle())
                    .disabled(!canSend)
                    // No bare-Return key equivalent: the field is multi-line, and
                    // claiming Return app-wide would stop you typing one. On the
                    // Mac, Return still sends through .onSubmit above; on iPad
                    // Return makes a new line and this button (or ⌘↩ with a
                    // hardware keyboard) sends.
                    .help("Send  (⌘↩)")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(12)
        .background(Palette.callout)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: Voice

    /// Tap to dictate; press and hold the button's menu for hands-free chat.
    private var micButton: some View {
        Button {
            if voiceChat.isActive {
                voiceChat.stop()
            } else if listener.isListening {
                let heard = listener.stop()
                if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send(heard) }
            } else {
                listener.autoStopOnSilence = false
                Task { await listener.start() }
            }
        } label: {
            ZStack {
                if listener.isListening {
                    Circle()
                        .fill(Palette.accent.opacity(0.18))
                        .scaleEffect(0.7 + listener.level * 0.5)
                }
                Image(systemName: micIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(listener.isListening || voiceChat.isActive ? Palette.accent : Palette.mutedText)
            }
            .frame(width: 30, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(micHelp)
        .contextMenu {
            Button {
                voiceChat.isActive ? voiceChat.stop() : voiceChat.start()
            } label: {
                Label(voiceChat.isActive ? "Stop voice chat" : "Start voice chat",
                      systemImage: "waveform.circle")
            }
            if speaker.isSpeaking {
                Button {
                    speaker.stop()
                } label: {
                    Label("Stop speaking", systemImage: "speaker.slash")
                }
            }
        }
    }

    private var micIcon: String {
        if voiceChat.isActive { return speaker.isSpeaking ? "speaker.wave.2.fill" : "waveform.circle.fill" }
        return listener.isListening ? "mic.fill" : "mic"
    }

    private var micHelp: String {
        if voiceChat.isActive { return "Voice chat is on — tap to stop" }
        if listener.isListening { return "Listening — tap to send what you said" }
        return "Tap to talk. Right-click for hands-free voice chat."
    }

    // MARK: Attaching

    /// Reading a long PDF takes a moment, so it happens off the main thread —
    /// the panel stays responsive while a big deck is being read.
    private func attach(_ urls: [URL]) {
        Task {
            for url in urls {
                guard let file = await AIAttachment.make(url: url) else { continue }
                attachments.append(file)
            }
            composerFocused = true
        }
    }

    // MARK: Requests coming from other pages

    private func takePendingRequest() {
        guard let request = bridge.pending, !ai.isStreaming else { return }
        bridge.pending = nil
        // A summarise from Study starts its own chat, so the file has the
        // screen to itself rather than landing under an unrelated thread.
        // Leaving `chat` nil makes send() create one — nothing empty is stored.
        if chat?.messages.isEmpty == false { chat = nil }
        attachments = request.attachments
        send(request.prompt)
    }

    // MARK: Sending

    private func newConversation() -> AIConversation {
        let fresh = AIConversation()
        context.insert(fresh)
        try? context.save()
        return fresh
    }

    /// Nothing is written until the first message, so empty "New chat" rows
    /// never pile up in the store.
    private func startNewChat() {
        attachments = []
        draft = ""
        chat = nil
    }

    private func send(_ text: String, spoken: Bool = false) {
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ai.isStreaming else { return }
        if prompt.isEmpty {
            guard !attachments.isEmpty else { return }
            prompt = attachments.count == 1
                ? "Summarise this file. Lead with one line on what it is, then the substance in short sections, then anything that looks examinable."
                : "Summarise each of these files, one short section per file, then one paragraph on what they have in common."
        }
        let conversation = chat ?? newConversation()
        chat = conversation
        draft = ""

        let files = attachments
        attachments = []

        let question = AIMessage(role: "user", text: prompt,
                                 attachmentNames: files.map(\.name))
        question.conversation = conversation
        context.insert(question)
        if conversation.title == "New chat" {
            conversation.title = String((files.first?.name ?? prompt).prefix(42))
        }
        conversation.updatedAt = .now
        try? context.save()

        let history = conversation.ordered
            .dropLast()
            .suffix(16)
            .map { (role: $0.isUser ? "user" : "model", text: $0.text) }

        let snapshot = AIContextBuilder.snapshot(context: context, github: github)
        // A spoken answer is written to be heard, not read.
        let systemPrompt = LifeAI.systemPrompt(snapshot: snapshot,
                                               spoken: spoken || voiceChat.isActive)
        let store = context

        // Held on the client so the Stop button can actually cancel it.
        ai.task = Task {
            let result = await ai.send(
                history: Array(history),
                prompt: prompt,
                attachments: files,
                systemPrompt: systemPrompt,
                retrieve: { query in AIIndex.shared.retrieve(query, context: store) },
                perform: { action in LifeAIActions.perform(action, context: store) }
            )
            // Release the finished task so it stops holding the attachments'
            // bytes and the store alive until the next message.
            defer { ai.task = nil }
            // After Stop, keep whatever had already been written; drop nothing else.
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "Stopped." else { return }
            let answer = AIMessage(role: "model", text: result.text,
                                   sources: result.sources, actions: result.actions)
            answer.conversation = conversation
            store.insert(answer)
            conversation.updatedAt = .now
            try? store.save()

            if voiceChat.isActive {
                voiceChat.speak(result.text)      // …then it listens again
            } else if voice.speakEveryReply {
                speaker.speak(result.text)
            }
        }
    }
}

// MARK: - Attachment chips

private struct AttachmentStrip: View {
    let attachments: [AIAttachment]
    let remove: (AIAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(attachments) { file in
                HStack(spacing: 7) {
                    Image(systemName: file.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(file.wasRead ? Palette.accent : Color(hex: "C0453F"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(file.note)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Palette.mutedText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        remove(file)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.mutedText)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Palette.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }
}

// MARK: - Bubbles

private struct LifeAIBubble: View {
    let message: AIMessage

    var body: some View {
        if message.isUser {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(message.attachmentNames.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "paperclip")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.mutedText)
                        .lineLimit(1)
                }
                HStack {
                    Spacer(minLength: 40)
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Palette.accent)
                        .foregroundStyle(Palette.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                AIMarkdownText(text: message.text)
                if !message.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(message.actions.enumerated()), id: \.offset) { _, action in
                            Label(action, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                }
                if !message.sources.isEmpty {
                    SourceChips(sources: message.sources)
                }
                AnswerToolbar(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Copy, read aloud, and save this answer into a subject's notes.
private struct AnswerToolbar: View {
    let text: String
    @ObservedObject private var speaker = Speaker.shared
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Platform.copy(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Palette.accent : Palette.mutedText)

            Button {
                speaker.isSpeaking ? speaker.stop() : speaker.speak(text)
            } label: {
                Label(speaker.isSpeaking ? "Stop" : "Listen",
                      systemImage: speaker.isSpeaking ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(speaker.isSpeaking ? Palette.accent : Palette.mutedText)
            .help("Read this answer aloud")

            SaveToSubjectMenu(text: text, heading: AINotes.suggestedHeading(for: text), title: "Save to notes")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

/// Puts a piece of text into the Notes of whichever subject you pick.
struct SaveToSubjectMenu: View {
    let text: String
    let heading: String
    var title: String = "Save to notes"

    @Environment(\.modelContext) private var context
    @Query(sort: \StudySubject.sortIndex) private var subjects: [StudySubject]
    @State private var savedTo: String?

    var body: some View {
        if let savedTo {
            Label("Saved to \(savedTo)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.accent)
        } else if subjects.isEmpty {
            EmptyView()
        } else {
            Menu {
                ForEach(subjects) { subject in
                    Button {
                        AINotes.append(text, heading: heading, to: subject, context: context)
                        savedTo = subject.name
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { savedTo = nil }
                    } label: {
                        Text("\(subject.emoji)  \(subject.name)")
                    }
                }
            } label: {
                Label(title, systemImage: "text.badge.plus")
                    .font(.system(size: 10, weight: .medium))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Palette.mutedText)
            .help("Append this to a subject's Notes")
        }
    }
}

private struct LifeAIStreamingBubble: View {
    let text: String
    let activity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !activity.isEmpty {
                Label(activity, systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.mutedText)
            }
            if text.isEmpty && activity.isEmpty {
                TypingDots()
            } else if !text.isEmpty {
                AIMarkdownText(text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TypingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Palette.mutedText)
                    .frame(width: 6, height: 6)
                    .opacity(phase == index ? 1 : 0.35)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

private struct SourceChips: View {
    let sources: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("from your material")
                .font(.mono(9, .bold))
                .foregroundStyle(Palette.mutedText)
            ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { _, source in
                Label(source, systemImage: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.mutedText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.subtleFill)
                    .clipShape(Capsule())
            }
        }
    }
}

/// Stacked suggestions shown on an empty chat.
private struct StarterChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { action(item) } label: {
                    Text(item)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.subtleFill)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Keys and endpoints

/// One sheet for every provider: paste a key beside whichever you use, and
/// point the custom row at anything that speaks the OpenAI chat API.
struct LifeAIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = LifeAI.shared

    @State private var typed: [String: String] = [:]
    @State private var customBase = AIProviderStore.customBaseURL
    @State private var customName = AIProviderStore.customName
    @State private var checking = false
    @State private var result: String?
    @State private var resultIsGood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI keys").font(.mono(16, .bold))
                Text("Life AI works with any of these. Keys are kept in the Keychain — never in the database, and each request goes straight from this device to the provider you picked.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(Palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AIProvider.allCases) { provider in
                        providerRow(provider)
                    }
                }
                .padding(20)
            }

            Divider().overlay(Palette.hairline)

            VStack(alignment: .leading, spacing: 10) {
                if let result {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(resultIsGood ? Palette.accent : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(checking ? "Testing…" : "Test \(ai.providerTitle)") { test() }
                        .disabled(checking)
                    Spacer()
                    Button("Done") { save(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .sheetFrame(width: 520, height: 560)
    }

    @ViewBuilder
    private func providerRow(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    save()
                    ai.provider = provider
                    Task { await ai.loadModelsIfNeeded() }
                } label: {
                    Image(systemName: provider == ai.provider ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(provider == ai.provider ? Palette.accent : Palette.mutedText)
                }
                .buttonStyle(.plain)
                .help("Use this one")

                Text(provider == .custom ? "\(customName.isEmpty ? "Custom" : customName) — OpenAI-compatible" : provider.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if AIProviderStore.hasKey(provider) {
                    Text(AIProviderStore.masked(provider))
                        .font(.mono(10))
                        .foregroundStyle(Palette.accent)
                }
            }

            Text(provider.blurb)
                .font(.system(size: 11))
                .foregroundStyle(Palette.mutedText)

            if provider == .custom {
                TextField("Name it — DeepSeek, Ollama, OpenRouter…",
                          text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextField("https://api.deepseek.com/v1  ·  http://localhost:11434/v1",
                          text: $customBase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            HStack(spacing: 8) {
                SecureField(provider.keyHint,
                            text: Binding(get: { typed[provider.rawValue] ?? "" },
                                          set: { typed[provider.rawValue] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if AIProviderStore.hasKey(provider) {
                    Button("Remove", role: .destructive) {
                        ai.setKey("", for: provider)
                        typed[provider.rawValue] = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
                if !provider.consoleURL.isEmpty, let url = URL(string: provider.consoleURL) {
                    Link("Get one", destination: url)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(14)
        .background(provider == ai.provider ? Palette.callout : Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(provider == ai.provider ? Palette.accent.opacity(0.5) : Palette.hairline, lineWidth: 1))
    }

    private func save() {
        for provider in AIProvider.allCases {
            let value = (typed[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { ai.setKey(value, for: provider) }
        }
        typed = [:]
        AIProviderStore.customBaseURL = customBase
        AIProviderStore.customName = customName
    }

    private func test() {
        save()
        checking = true
        result = nil
        // This view has no @Query, so it isn't actor-inferred — say so, or the
        // continuation resumes off the main thread and writes @State there.
        Task { @MainActor in
            let error = await ai.verifyKey()
            resultIsGood = error == nil
            result = error ?? "Works — \(ai.models.count) model\(ai.models.count == 1 ? "" : "s") available on \(ai.providerTitle)."
            checking = false
        }
    }
}

// MARK: - Settings section

/// The Life AI block in Settings: provider, model, voice, and the index.
struct LifeAISection: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var ai = LifeAI.shared
    @ObservedObject private var index = AIIndex.shared
    @ObservedObject private var voice = VoiceSettings.shared
    @State private var showingKeySheet = false
    @State private var indexedCount = 0

    var body: some View {
        Section("Life AI") {
            LabeledContent("AI") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { ai.provider },
                                                  set: { ai.provider = $0; Task { await ai.loadModelsIfNeeded() } })) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.shortTitle).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(AIProviderStore.hasKey(ai.provider) ? ai.maskedKey : "no key")
                        .font(.mono(11))
                        .foregroundStyle(AIProviderStore.hasKey(ai.provider) ? Palette.accent : Palette.mutedText)
                    Button("Keys…") { showingKeySheet = true }
                        .buttonStyle(.borderless)
                }
            }

            LabeledContent("Model") {
                HStack(spacing: 8) {
                    if ai.models.isEmpty {
                        Text(ai.modelName.isEmpty ? "none" : ai.modelName)
                            .font(.mono(11))
                            .foregroundStyle(Palette.mutedText)
                        Button(ai.isLoadingModels ? "Loading…" : "Load list") {
                            Task { _ = await ai.reloadModels() }
                        }
                        .buttonStyle(.borderless)
                        .disabled(ai.isLoadingModels)
                    } else {
                        Picker("", selection: Binding(get: { ai.modelName }, set: { ai.modelName = $0 })) {
                            ForEach(ai.models) { model in
                                Text(model.shortTitle).tag(model.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            Text("The model list comes from your own key, so it always matches what the provider will actually accept.")
                .font(.caption).foregroundStyle(Palette.mutedText)

            Picker("Voice language", selection: Binding(get: { voice.language },
                                                        set: { voice.language = $0 })) {
                ForEach(VoiceLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            Toggle(isOn: Binding(get: { voice.speakEveryReply },
                                 set: { voice.speakEveryReply = $0 })) {
                Label("Read answers aloud", systemImage: "speaker.wave.2")
            }
            Text("Tap the microphone in the panel to talk instead of typing. Right-click it for hands-free voice chat: it listens, sends when you stop, reads the answer back and listens again. Speech is handled by the system, on the device where a model exists for the language.")
                .font(.caption).foregroundStyle(Palette.mutedText)

            LabeledContent("Material index") {
                HStack(spacing: 8) {
                    Text(index.isIndexing ? index.progressText : "\(indexedCount) passages")
                        .font(.mono(11))
                        .foregroundStyle(Palette.mutedText)
                        .lineLimit(1)
                    Button("Rebuild") {
                        Task {
                            await index.refresh(context: context, force: true)
                            refreshCount()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(index.isIndexing)
                }
            }

            Text("Life AI reads your habits, schedule, timetable, subjects and their files, calendar, progress and GitHub, plus any document you attach. It cannot see your Journal. Nothing is stored on any server of ours, because there isn't one.")
                .font(.caption).foregroundStyle(Palette.mutedText)
        }
        .sheet(isPresented: $showingKeySheet) { LifeAIKeySheet() }
        .task {
            refreshCount()
            await ai.loadModelsIfNeeded()
        }
    }

    private func refreshCount() {
        indexedCount = (try? context.fetchCount(FetchDescriptor<AIChunk>())) ?? 0
    }
}

// MARK: - Markdown

/// A small Markdown renderer: headings, bullets, numbered lists, paragraphs
/// with inline styling, and fenced code blocks with copy and save buttons.
struct AIMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(AIMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let body):
                    Text(inline(body))
                        .font(.system(size: level == 1 ? 16 : (level == 2 ? 14.5 : 13.5), weight: .bold))
                        .textSelection(.enabled)
                case .paragraph(let body):
                    Text(inline(body))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(ordered ? "\(position + 1)." : "•")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.mutedText)
                                Text(inline(item))
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(let language, let body):
                    CodeBlock(language: language, code: body)
                case .rule:
                    Divider().overlay(Palette.hairline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}

enum AIMarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case list([String], ordered: Bool)
    case code(String, String)
    case rule

    static func parse(_ text: String) -> [AIMarkdownBlock] {
        var blocks: [AIMarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var bulletsOrdered = false
        var codeLines: [String] = []
        var codeLanguage = ""
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.list(bullets, ordered: bulletsOrdered)) }
            bullets = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLanguage, codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = ""
                    inCode = false
                } else {
                    flushParagraph(); flushBullets()
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(raw); continue }

            if line.isEmpty { flushParagraph(); flushBullets(); continue }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph(); flushBullets()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph(); flushBullets()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(min(level, 3),
                                       String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                if !bullets.isEmpty && bulletsOrdered { flushBullets() }
                bulletsOrdered = false
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if let dot = line.firstIndex(of: "."),
               line.distance(from: line.startIndex, to: dot) <= 2,
               Int(line[line.startIndex..<dot]) != nil,
               line.index(after: dot) < line.endIndex {
                flushParagraph()
                if !bullets.isEmpty && !bulletsOrdered { flushBullets() }
                bulletsOrdered = true
                bullets.append(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushBullets()
            paragraph.append(line)
        }
        if inCode && !codeLines.isEmpty {
            blocks.append(.code(codeLanguage, codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        flushBullets()
        return blocks
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(language.isEmpty ? "code" : language)
                    .font(.mono(9, .bold))
                    .foregroundStyle(Palette.mutedText)
                Spacer(minLength: 0)
                SaveToSubjectMenu(text: "```\(language)\n\(code)\n```",
                                  heading: language.isEmpty ? "Code from Life AI" : "\(language) from Life AI",
                                  title: "Save")
                Button {
                    Platform.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Palette.accent : Palette.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.subtleFill)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.mono(11.5))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.elevated)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
