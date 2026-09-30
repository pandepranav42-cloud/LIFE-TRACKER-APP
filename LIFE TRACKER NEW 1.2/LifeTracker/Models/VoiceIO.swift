import Foundation
import SwiftUI
import AVFoundation
import Speech

// MARK: - Talking to Life AI
//
// Two halves, both using what the system already has — no service is called
// for speech, and audio never leaves the device unless Apple's own recogniser
// falls back to the server for a language with no on-device model.
//
//   SpeechListener  microphone → text (Speech framework)
//   Speaker         text → spoken audio (AVSpeechSynthesizer)
//
// The panel wires them into a loop for hands-free conversation: listen, send
// when you stop talking, speak the answer, listen again.

// MARK: Which language to listen for

enum VoiceLanguage: String, CaseIterable, Identifiable, Codable {
    case automatic, english, korean, chinese, hindi, marathi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Match my device"
        case .english:   return "English"
        case .korean:    return "한국어"
        case .chinese:   return "中文"
        case .hindi:     return "हिन्दी"
        case .marathi:   return "मराठी"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .automatic: return Locale.current.identifier
        case .english:   return "en-US"
        case .korean:    return "ko-KR"
        case .chinese:   return "zh-CN"
        case .hindi:     return "hi-IN"
        case .marathi:   return "mr-IN"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }
}

// MARK: - Microphone → text

@MainActor
final class SpeechListener: NSObject, ObservableObject {
    static let shared = SpeechListener()

    /// What has been heard so far in this stretch of speaking.
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    /// 0…1, for the little level bar on the mic button.
    @Published private(set) var level: Double = 0
    @Published var errorText: String?

    /// Fires when you stop talking for a moment, with the finished transcript.
    /// Voice chat uses this to send without you pressing anything.
    var onSilence: ((String) -> Void)?
    /// How long a pause counts as "finished talking".
    var silenceAfter: TimeInterval = 1.6
    /// Off for plain dictation, on for the hands-free loop.
    var autoStopOnSilence = false

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?

    private override init() { super.init() }

    var isAvailable: Bool {
        SFSpeechRecognizer(locale: VoiceSettings.shared.language.locale)?.isAvailable ?? false
    }

    // MARK: Permission

    /// Asks for speech recognition and the microphone, in that order.
    func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else {
            errorText = "Speech recognition is turned off for LifeTracker. Turn it on in System Settings → Privacy & Security → Speech Recognition."
            return false
        }
        let microphone = await Self.requestMicrophone()
        if !microphone {
            errorText = "LifeTracker can't use the microphone. Turn it on in System Settings → Privacy & Security → Microphone."
        }
        return microphone
    }

    private static func requestMicrophone() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        #else
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        #endif
    }

    // MARK: Listening

    func start() async {
        guard !isListening else { return }
        errorText = nil
        transcript = ""

        guard await requestAccess() else { return }

        let locale = VoiceSettings.shared.language.locale
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            errorText = "No speech recogniser is available for \(locale.identifier). Pick another language in Settings → Life AI."
            return
        }
        self.recognizer = recognizer

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it on the device where a model exists for the language.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorText = "No microphone input is available."
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let peak = Self.peak(of: buffer)
            Task { @MainActor [weak self] in self?.level = peak }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            cleanUp()
            return
        }

        isListening = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.restartSilenceTimer()
                }
                if error != nil || (result?.isFinal ?? false) {
                    // A recogniser error after some speech isn't worth showing —
                    // the transcript is already there.
                    self.finish()
                }
            }
        }
    }

    /// Stops listening and returns what was heard.
    @discardableResult
    func stop() -> String {
        let heard = transcript
        finish()
        return heard
    }

    private func finish() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard isListening else { cleanUp(); return }
        isListening = false
        cleanUp()
    }

    private func cleanUp() {
        // Order matters: the tap runs on the audio thread and appends to the
        // request, so it has to be detached before the request is closed.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func restartSilenceTimer() {
        guard autoStopOnSilence else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceAfter, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                let heard = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finish()
                if !heard.isEmpty { self.onSilence?(heard) }
            }
        }
    }

    private nonisolated static func peak(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        // Perceptually the raw RMS is tiny; lift it into a usable 0…1.
        return min(1, Double(rms) * 12)
    }
}

// MARK: - Text → speech

@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    @Published private(set) var isSpeaking = false
    /// Fires when an utterance finishes on its own (not when stopped).
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var wasStopped = false
    /// The utterance being read right now. A `didCancel` for an older one must
    /// not clear `isSpeaking` for the one that replaced it.
    private var current: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ markdown: String) {
        stop()
        let text = Self.speakable(markdown)
        guard !text.isEmpty else { onFinish?(); return }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        wasStopped = false
        current = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        guard synthesizer.isSpeaking else { isSpeaking = false; return }
        wasStopped = true
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.current else { return }
            self.current = nil
            self.isSpeaking = false
            if !self.wasStopped { self.onFinish?() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.current else { return }
            self.current = nil
            self.isSpeaking = false
        }
    }

    /// Picks a voice for the language the text is actually in, so a Korean
    /// answer isn't read with an English accent.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let setting = VoiceSettings.shared.language
        if setting != .automatic {
            return AVSpeechSynthesisVoice(language: setting.localeIdentifier)
        }
        let script = detectLanguage(text)
        return AVSpeechSynthesisVoice(language: script)
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    /// Cheap and good enough: look at which script the characters are in.
    private static func detectLanguage(_ text: String) -> String {
        var hangul = 0, han = 0, devanagari = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x0900...0x097F:                  devanagari += 1
            case 0x0041...0x007A:                  latin += 1
            default: break
            }
        }
        let best = max(hangul, han, devanagari, latin)
        if best == 0 { return Locale.current.identifier }
        if best == hangul { return "ko-KR" }
        if best == han { return "zh-CN" }
        if best == devanagari { return "hi-IN" }
        return "en-US"
    }

    /// Markdown reads terribly out loud. Strip it down to sentences, and skip
    /// code entirely rather than spelling out punctuation for a minute.
    static func speakable(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        var skippedCode = false

        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                if inCode { skippedCode = true }
                continue
            }
            if inCode { continue }
            if line == "---" || line == "***" || line == "___" { continue }

            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = String(line.dropFirst(2))
            }
            line = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "|", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A line that doesn't end in punctuation gets a full stop, so the
            // synthesiser pauses instead of running two points together.
            if let last = line.last, !".!?:;,。？！".contains(last) { line += "." }
            lines.append(line)
        }
        var text = lines.joined(separator: " ")
        if skippedCode {
            text += text.isEmpty ? "There's code in this answer — read it on screen."
                                 : " The code is on screen."
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Hands-free conversation
//
// Listen → send when you stop talking → speak the answer → listen again, until
// you turn it off. Kept here rather than in the view so the callbacks always
// see the live state instead of a snapshot taken when the view was built.

@MainActor
final class VoiceChat: ObservableObject {
    static let shared = VoiceChat()

    @Published private(set) var isActive = false
    /// Set by the panel — what to do with a finished utterance.
    var onUtterance: ((String) -> Void)?

    private let listener = SpeechListener.shared
    private let speaker = Speaker.shared

    private init() {
        speaker.onFinish = { [weak self] in
            guard let self, self.isActive else { return }
            Task { await self.listen() }
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        listener.onSilence = { [weak self] heard in
            guard let self, self.isActive else { return }
            self.onUtterance?(heard)
        }
        Task { await listen() }
    }

    func stop() {
        isActive = false
        listener.autoStopOnSilence = false
        listener.onSilence = nil
        listener.stop()
        speaker.stop()
    }

    /// Reads an answer aloud, then goes back to listening.
    func speak(_ answer: String) {
        guard isActive else { return }
        speaker.speak(answer)
    }

    private func listen() async {
        guard isActive, !speaker.isSpeaking else { return }
        listener.autoStopOnSilence = true
        await listener.start()
    }
}

// MARK: - Voice settings

final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    private static let languageKey = "lifeAI.voiceLanguage"
    private static let speakRepliesKey = "lifeAI.speakReplies"

    /// Which language the recogniser listens for, and which voice reads back.
    @Published var language: VoiceLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    /// Read every answer aloud, even ones typed rather than spoken.
    @Published var speakEveryReply: Bool {
        didSet { UserDefaults.standard.set(speakEveryReply, forKey: Self.speakRepliesKey) }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
        language = VoiceLanguage(rawValue: saved) ?? .automatic
        speakEveryReply = UserDefaults.standard.bool(forKey: Self.speakRepliesKey)
    }
}
