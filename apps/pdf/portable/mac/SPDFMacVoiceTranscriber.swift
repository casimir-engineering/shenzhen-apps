// Voice input for the assistant's composer: speech from the microphone turned into text on this Mac by Apple's
// SpeechAnalyzer (macOS 26). Nothing here sends audio anywhere; the chat view only receives text.
//
// The Objective-C side (SPDFMacAIChatVoice.mm) finds this class with NSClassFromString, so builds that do not compile
// this file (the test binaries) simply have no microphone button. SPDFMacVoiceTranscriber.h declares what it calls.
//
// A session: start (microphone) or start with an audio file (the off-screen harness feeds recordings through the same
// path), then text arrives through onText as (final, volatile): the words settled so far, and the words still being
// recognised, which later results replace. stop() lets the words already heard settle, delivers them, then reports
// "stopped"; cancel() reports nothing more. Every callback runs on the main thread.
import AVFoundation
import Carbon
import Foundation
import Speech

@objc(SPDFVoiceTranscriber)
public final class SPDFVoiceTranscriber: NSObject {
    // (final, volatile): the whole session's settled text, and the words not yet settled.
    @objc public var onText: ((String, String) -> Void)?
    // "preparing", "downloading" (with the fraction done), "listening", "finishing", "stopped".
    @objc public var onState: ((String, Double) -> Void)?
    // A kind ("microphone", "language", "download", "audio", "engine") and a message for the log.
    @objc public var onError: ((String, String) -> Void)?
    private var engine: AnyObject?

    @objc public static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    // 0: not asked yet, 1: allowed, 2: denied or restricted. Never asks.
    @objc public static var microphoneStatus: Int {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return 1
        case .notDetermined: return 0
        default: return 2
        }
    }

    // Asks macOS for the microphone (its own prompt, once); `done` gets the answer on the main thread.
    @objc(requestMicrophone:) public static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
    }

    // The languages speech can be turned into text in (BCP 47), and those whose model is already on this Mac.
    @objc(loadLanguages:) public static func loadLanguages(_ done: @escaping ([String], [String]) -> Void) {
        guard #available(macOS 26.0, *) else { done([], []); return }
        Task.detached(priority: .utility) {
            var supported = Set<String>(), installed = Set<String>()
            for locale in await SpeechTranscriber.supportedLocales { supported.insert(locale.identifier(.bcp47)) }
            for locale in await DictationTranscriber.supportedLocales { supported.insert(locale.identifier(.bcp47)) }
            for locale in await SpeechTranscriber.installedLocales { installed.insert(locale.identifier(.bcp47)) }
            for locale in await DictationTranscriber.installedLocales { installed.insert(locale.identifier(.bcp47)) }
            let s = supported.sorted(), i = installed.intersection(supported).sorted()
            DispatchQueue.main.async { done(s, i) }
        }
    }

    // The language of the keyboard input source in use (Pinyin: zh-Hans, U.S.: en), most specific first.
    @objc public static var inputSourceLanguages: [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        return languages.first.map { [$0] } ?? []
    }

    // The supported language that best matches `language` (an input source's "zh-Hans", or a chosen "fr-CH"): the
    // person's own variant of it from their preferred languages, else its usual region, else whatever macOS pairs it
    // with. nil when speech in that language can't be recognised here.
    @objc(resolveLanguage:done:) public static func resolveLanguage(_ language: String, done: @escaping (String?) -> Void) {
        guard #available(macOS 26.0, *) else { done(nil); return }
        Task.detached(priority: .userInitiated) {
            let found = await VoiceEngine.resolve(language)
            DispatchQueue.main.async { done(found) }
        }
    }

    @objc(startWithLanguage:) public func start(language: String) { begin(language: language, file: nil, realTime: false) }

    // The same session fed from a recording instead of the microphone, in real time or as fast as it reads.
    @objc(startWithLanguage:audioFile:realTime:)
    public func start(language: String, audioFile: URL, realTime: Bool) { begin(language: language, file: audioFile, realTime: realTime) }

    @objc public func stop() {
        if #available(macOS 26.0, *) { (engine as? VoiceEngine)?.stop() }
    }

    @objc public func cancel() {
        if #available(macOS 26.0, *) { (engine as? VoiceEngine)?.cancel() }
        engine = nil
    }

    private func begin(language: String, file: URL?, realTime: Bool) {
        guard #available(macOS 26.0, *) else { onError?("engine", "Voice input needs macOS 26."); return }
        cancel()
        let session = VoiceEngine(
            text: { [weak self] final, volatile in self?.onText?(final, volatile) },
            state: { [weak self] state, fraction in self?.onState?(state, fraction) },
            error: { [weak self] kind, message in self?.onError?(kind, message) })
        engine = session
        session.run(language: language, file: file, realTime: realTime)
    }
}

@available(macOS 26.0, *)
private final class VoiceEngine: @unchecked Sendable {
    private let text: (String, String) -> Void
    private let state: (String, Double) -> Void
    private let error: (String, String) -> Void
    private let lock = NSLock()
    private var cancelled = false, stopping = false
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var audio: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var final = "", volatile = ""
    private var spaced = true
    private var progress: NSKeyValueObservation?
    private var task: Task<Void, Never>?

    init(text: @escaping (String, String) -> Void, state: @escaping (String, Double) -> Void,
         error: @escaping (String, String) -> Void) {
        self.text = text
        self.state = state
        self.error = error
    }

    static func resolve(_ language: String) async -> String? {
        let base = Locale(identifier: language)
        let code = base.language.languageCode?.identifier ?? language
        var candidates: [Locale] = []
        if base.region != nil { candidates.append(base) }
        for preferred in Locale.preferredLanguages {
            let locale = Locale(identifier: preferred)
            if locale.language.languageCode?.identifier == code, locale.region != nil,
               base.language.script == nil || locale.language.script == nil || locale.language.script == base.language.script {
                candidates.append(locale)
            }
        }
        let usual = ["en": "en-US", "fr": "fr-FR", "es": "es-ES", "pt": "pt-BR", "de": "de-DE", "it": "it-IT",
                     "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "zh": "zh-CN", "yue": "yue-CN", "ja": "ja-JP", "ko": "ko-KR"]
        if let pick = usual[language] ?? usual[code] { candidates.append(Locale(identifier: pick)) }
        candidates.append(base)
        for locale in candidates {
            if let found = await SpeechTranscriber.supportedLocale(equivalentTo: locale) { return found.identifier(.bcp47) }
            if let found = await DictationTranscriber.supportedLocale(equivalentTo: locale) { return found.identifier(.bcp47) }
        }
        return nil
    }

    // The request that puts the language's model on this Mac. An app may keep only a few languages; past that, the
    // one used longest ago makes room.
    static func installation(for module: any SpeechModule, locale: Locale) async throws -> AssetInstallationRequest? {
        do { return try await AssetInventory.assetInstallationRequest(supporting: [module]) } catch {
            let reserved = await AssetInventory.reservedLocales
            guard reserved.count >= AssetInventory.maximumReservedLocales,
                  let oldest = reserved.first(where: { $0.identifier(.bcp47) != locale.identifier(.bcp47) }) else { throw error }
            await AssetInventory.release(reservedLocale: oldest)
            return try await AssetInventory.assetInstallationRequest(supporting: [module])
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func report(_ kind: String, _ message: String) {
        if isCancelled { return }
        DispatchQueue.main.async { [self] in if !isCancelled { error(kind, message) } }
    }

    private func announce(_ name: String, _ fraction: Double = 0) {
        if isCancelled { return }
        DispatchQueue.main.async { [self] in if !isCancelled { state(name, fraction) } }
    }

    private func publish() {
        lock.lock(); let settled = final, open = volatile; lock.unlock()
        DispatchQueue.main.async { [self] in if !isCancelled { text(settled, open) } }
    }

    func run(language: String, file: URL?, realTime: Bool) {
        announce("preparing")
        task = Task.detached(priority: .userInitiated) { [self] in
            do { try await session(language: language, file: file, realTime: realTime) } catch {
                report("engine", "\(error)")
                teardownAudio()
                announce("stopped")
            }
        }
    }

    private func session(language: String, file: URL?, realTime: Bool) async throws {
        let locale = Locale(identifier: language)
        spaced = !["zh", "ja", "yue", "th", "wuu"].contains(locale.language.languageCode?.identifier ?? "")
        let module: any SpeechModule
        let results: Task<Void, Error>
        let selected: Locale
        if let found = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            selected = found
            let transcriber = SpeechTranscriber(locale: found, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            module = transcriber
            results = Task { for try await result in transcriber.results { take(String(result.text.characters), final: result.isFinal) } }
        } else if let found = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            selected = found
            let transcriber = DictationTranscriber(locale: found, preset: .progressiveShortDictation)
            module = transcriber
            results = Task { for try await result in transcriber.results { take(String(result.text.characters), final: result.isFinal) } }
        } else {
            report("language", "No speech model for \(language)")
            announce("stopped")
            return
        }
        // A model already on the Mac still answers with a request that finishes at once; the button shows
        // downloading only for one that takes a while.
        let request: AssetInstallationRequest?
        do { request = try await VoiceEngine.installation(for: module, locale: selected) } catch {
            results.cancel()
            report("download", "\(error)")
            announce("stopped")
            return
        }
        if let request {
            let watch = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                announce("downloading", request.progress.fractionCompleted)
                progress = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    self?.announce("downloading", progress.fractionCompleted)
                }
            }
            defer { progress = nil }
            do { try await request.downloadAndInstall() } catch {
                watch.cancel()
                results.cancel()
                report("download", "\(error)")
                announce("stopped")
                return
            }
            watch.cancel()
            await watch.value
        }
        if isCancelled { results.cancel(); return }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        lock.withLock { self.input = continuation; self.analyzer = analyzer; self.format = format }
        try await analyzer.start(inputSequence: stream)
        if let file { try await feed(file: file, realTime: realTime) } else { try startMicrophone() }
        announce("listening")
        _ = try? await results.value
        if !isCancelled { publish() }
        announce("stopped")
    }

    // Each result is a stretch of speech; in a language written with spaces, stretches are joined by one.
    private func take(_ words: String, final isFinal: Bool) {
        lock.lock()
        var piece = words
        if spaced, let last = final.last, !last.isWhitespace, let first = piece.first, !first.isWhitespace,
           !first.isPunctuation { piece = " " + piece }
        if isFinal { final += piece; volatile = "" } else { volatile = piece }
        lock.unlock()
        publish()
    }

    // One buffer of sound, in whatever format it came, into the analyzer's own format.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let target = format, continuation = input; lock.unlock()
        guard let continuation else { return }
        guard let target, buffer.format != target else { continuation.yield(AnalyzerInput(buffer: buffer)); return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if failure == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else {
            report("audio", "No microphone input")
            throw NSError(domain: "SPDFVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: natural) { [weak self] buffer, _ in self?.feed(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            report("audio", "\(error)")
            throw error
        }
        lock.lock(); audio = engine; lock.unlock()
    }

    private func feed(file url: URL, realTime: Bool) async throws {
        let file = try AVAudioFile(forReading: url)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        Task.detached(priority: .userInitiated) { [self] in
            let started = Date()
            var sent = 0.0
            while !isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                if buffer.frameLength == 0 { break }
                let open = lock.withLock { input != nil && !stopping }
                if !open { break }
                feed(buffer)
                sent += Double(buffer.frameLength) / file.processingFormat.sampleRate
                if realTime {
                    let ahead = sent - Date().timeIntervalSince(started)
                    if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
                }
            }
        }
    }

    private func teardownAudio() {
        lock.lock(); let engine = audio; audio = nil; lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    // No more sound; the words already heard settle, are delivered, then "stopped".
    func stop() {
        lock.lock()
        if stopping || cancelled { lock.unlock(); return }
        stopping = true
        let continuation = input, analyzer = self.analyzer
        lock.unlock()
        teardownAudio()
        announce("finishing")
        continuation?.finish()
        guard let analyzer else { cancel(); DispatchQueue.main.async { [state] in state("stopped", 0) }; return }
        Task.detached(priority: .userInitiated) { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = input, analyzer = self.analyzer
        input = nil
        lock.unlock()
        teardownAudio()
        progress = nil
        continuation?.finish()
        task?.cancel()
        if let analyzer { Task.detached { await analyzer.cancelAndFinishNow() } }
    }
}
