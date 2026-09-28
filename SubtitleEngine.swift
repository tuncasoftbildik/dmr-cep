/*
    Copyright (C) 2026 DroidStar-DMR contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import Foundation
import AVFAudio
import Speech
import Translation

// Live subtitles ("altyazı") for received DMR transmissions, fully on-device:
//   SpeechAnalyzer + SpeechTranscriber (English) or DictationTranscriber (Turkish), iOS 26+,
//   then Apple Translation en -> tr, with ham-radio fixes from SubtitleGlossary.swift.
//
// Threads / hand-off
//   C++ (DMR mode thread, 20 ms timer) calls the @_cdecl functions at the bottom:
//     ds_subtitle_begin(src, dst, key) / ds_subtitle_push_pcm(pcm, 160) / ds_subtitle_end()
//   Each call only copies the samples and yields an Event into an AsyncStream (a short internal
//   lock, no allocation beyond one 320-byte array, never waits for the recognizer). A single
//   consumer task (SubtitleWorker actor) drains the stream: it converts 8 kHz Int16 to the
//   analyzer's format in 100 ms buffers and feeds the per-transmission SpeechAnalyzer.
//   Results / status go back as JSON through the C callback registered with
//   ds_subtitle_set_callback (called on arbitrary threads; the C++ side queues to the Qt thread).
//
// One SpeechAnalyzer per transmission (clean finalize at the end of every over), with a spare
// analyzer created and prepareToAnalyze()'d in the background after each one so the next
// transmission starts warm. The model stays loaded (modelRetention: .processLifetime).
//
// The same file is compiled for macOS by the test harness in ds-work/altyazi/stream-test.

// MARK: - Events

enum DSSubtitleEvent: Sendable {
    case configure(enabled: Bool, translate: Bool, language: String)
    case refreshStatus
    case begin(src: UInt32, dst: UInt32, key: String)
    case pcm([Int16])
    case end
}

public typealias DSSubtitleCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

final class DSSubtitleHub: @unchecked Sendable {
    static let shared = DSSubtitleHub()

    let continuation: AsyncStream<DSSubtitleEvent>.Continuation
    private let lock = NSLock()
    private var callback: DSSubtitleCallback?

    private init() {
        // 60 s of frames; the consumer only falls behind while an over is being finalized.
        var c: AsyncStream<DSSubtitleEvent>.Continuation!
        let stream = AsyncStream<DSSubtitleEvent>(bufferingPolicy: .bufferingNewest(3000)) { c = $0 }
        continuation = c
        if #available(iOS 26.0, macOS 26.0, *) {
            Task.detached(priority: .userInitiated) {
                await SubtitleWorker.shared.run(stream)
            }
        }
    }

    static var isSupported: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }

    func setCallback(_ cb: DSSubtitleCallback?) {
        lock.lock(); callback = cb; lock.unlock()
    }

    func emit(_ dict: [String: Any]) {
        lock.lock(); let cb = callback; lock.unlock()
        guard let cb = cb,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let s = String(data: data, encoding: .utf8) else { return }
        s.withCString { cb($0) }
    }

    func send(_ e: DSSubtitleEvent) { continuation.yield(e) }
}

func dsSubLog(_ s: String) { NSLog("[Altyazi] %@", s) }

/// SpeechAnalyzer runs on-device and is not documented to need speech-recognition authorization;
/// if an analyzer ever fails to start while the permission was never asked, ask once (the
/// NSSpeechRecognitionUsageDescription text is in Info.plist) so the next over can work.
func dsSubRequestSpeechAuthIfNeeded() {
    let st = SFSpeechRecognizer.authorizationStatus()
    dsSubLog("speech recognition authorization: \(st.rawValue)")
    if st == .notDetermined {
        SFSpeechRecognizer.requestAuthorization { s in dsSubLog("speech recognition authorization -> \(s.rawValue)") }
    }
}

// MARK: - Worker

@available(iOS 26.0, macOS 26.0, *)
actor SubtitleWorker {
    static let shared = SubtitleWorker()

    enum ModelState: String { case unknown, checking, downloading, ready, unsupported, failed }

    private var enabled = true
    private var translate = true
    private var language = "en"          // "en" (SpeechTranscriber + translation) or "tr" (DictationTranscriber)

    private var modelState: ModelState = .unknown
    private var modelProgress: Double = 0
    private var modelError = ""
    private var locale: Locale?
    private var preparing = false
    private var generation = 0            // bumps when the language changes

    private var spare: SubtitleRecognizer?
    private var warming = false
    private var current: SubtitleSession?
    nonisolated let translator = SubtitleTranslator()
    private var translationStatus = "unknown"

    // Tunables (the harness changes them).
    var fastResults = true
    func setFastResults(_ on: Bool) { fastResults = on; spare = nil }

    func run(_ stream: AsyncStream<DSSubtitleEvent>) async {
        for await e in stream {
            switch e {
            case let .configure(en, tr, lang):
                let langChanged = lang != language
                enabled = en; translate = tr; language = (lang == "tr") ? "tr" : "en"
                if langChanged {
                    generation += 1
                    modelState = .unknown; locale = nil; spare = nil
                }
                if enabled { startPrepare() } else { spare = nil }
                await refreshTranslation()
            case .refreshStatus:
                await refreshTranslation()
                if enabled { startPrepare() }
                emitStatus()
            case let .begin(src, dst, key):
                if let c = current {
                    current = nil
                    Task { await c.finish() }
                }
                guard enabled else { break }
                guard modelState == .ready, let loc = locale else {
                    dsSubLog("begin \(key): model not ready (\(modelState.rawValue)), no subtitles for this over")
                    startPrepare()
                    break
                }
                let rec: SubtitleRecognizer
                if let s = spare, s.generation == generation {
                    rec = s
                    spare = nil
                } else {
                    rec = SubtitleRecognizer(locale: loc, language: language, fast: fastResults, generation: generation)
                    dsSubLog("begin \(key): no warm analyzer, starting cold")
                }
                let doTranslate = translate && language == "en" && translationStatus == "installed"
                let s = SubtitleSession(key: key, src: src, dst: dst, recognizer: rec,
                                        translator: doTranslate ? translator : nil, language: language)
                current = s
                await s.start()
            case let .pcm(samples):
                if let c = current { await c.push(samples) }
            case .end:
                if let c = current {
                    current = nil
                    // Finalize off the event loop so the next over is not delayed.
                    Task { await c.finish() }
                }
                warmSpare()
            }
        }
    }

    // MARK: Model

    private func startPrepare() {
        guard !preparing, modelState != .ready, modelState != .unsupported else {
            if modelState == .ready { warmSpare() }
            return
        }
        preparing = true
        let gen = generation
        let lang = language
        Task { await self.prepareModel(gen: gen, lang: lang) }
    }

    private func prepareModel(gen: Int, lang: String) async {
        defer { preparing = false }
        modelState = .checking
        emitStatus()
        let wanted = Locale(identifier: lang == "tr" ? "tr_TR" : "en_US")
        let loc: Locale?
        if lang == "tr" {
            loc = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        } else {
            loc = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        }
        guard gen == generation else { return }
        guard let loc = loc else {
            modelState = .unsupported
            dsSubLog("recognizer: locale \(wanted.identifier) not supported on this device")
            emitStatus()
            return
        }
        let probe = SubtitleRecognizer(locale: loc, language: lang, fast: fastResults, generation: gen)
        let status = await AssetInventory.status(forModules: [probe.module])
        dsSubLog("recognizer \(loc.identifier): asset status \(status), speech auth \(SFSpeechRecognizer.authorizationStatus().rawValue)")
        if status == .unsupported {
            modelState = .unsupported
            emitStatus()
            return
        }
        if status != .installed {
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [probe.module]) {
                    modelState = .downloading
                    modelProgress = 0
                    emitStatus()
                    let t0 = Date()
                    let progress = req.progress
                    let poll = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await self?.setProgress(progress.fractionCompleted)
                        }
                    }
                    defer { poll.cancel() }
                    try await req.downloadAndInstall()
                    dsSubLog(String(format: "recognizer model installed in %.1f s", Date().timeIntervalSince(t0)))
                }
            } catch {
                modelState = .failed
                modelError = "\(error)"
                dsSubLog("recognizer model download failed: \(error)")
                emitStatus()
                return
            }
        }
        guard gen == generation else { return }
        locale = loc
        modelState = .ready
        emitStatus()
        warmSpare()
    }

    private func setProgress(_ p: Double) {
        guard modelState == .downloading else { return }
        modelProgress = p
        emitStatus()
    }

    /// Creates the next transmission's analyzer and loads the model into it ahead of time.
    private func warmSpare() {
        guard enabled, modelState == .ready, let loc = locale, spare == nil, !warming else { return }
        warming = true
        let rec = SubtitleRecognizer(locale: loc, language: language, fast: fastResults, generation: generation)
        Task {
            let t0 = Date()
            do {
                try await rec.prepare()
                dsSubLog(String(format: "warm analyzer ready in %.0f ms (format %@)", Date().timeIntervalSince(t0) * 1000, rec.format?.description ?? "-"))
                self.setSpare(rec)
            } catch {
                dsSubLog("warm analyzer failed: \(error)")
                self.setSpare(nil)
            }
        }
    }

    private func setSpare(_ r: SubtitleRecognizer?) {
        warming = false
        if let r = r, r.generation == generation { spare = r }
    }

    // MARK: Translation

    private func refreshTranslation() async {
        translationStatus = await translator.refresh()
        emitStatus()
    }

    private func emitStatus() {
        var d: [String: Any] = [
            "t": "status",
            "model": modelState.rawValue,
            "progress": modelProgress,
            "translation": translationStatus,
            "language": language,
        ]
        if !modelError.isEmpty { d["error"] = modelError }
        DSSubtitleHub.shared.emit(d)
    }

    func statusSnapshot() -> (String, String) { (modelState.rawValue, translationStatus) }
}

// MARK: - Recognizer (analyzer + module for one transmission)

@available(iOS 26.0, macOS 26.0, *)
final class SubtitleRecognizer: @unchecked Sendable {
    let module: any SpeechModule
    let analyzer: SpeechAnalyzer
    let generation: Int
    private(set) var format: AVAudioFormat?
    private let speech: SpeechTranscriber?
    private let dictation: DictationTranscriber?

    init(locale: Locale, language: String, fast: Bool, generation: Int) {
        self.generation = generation
        if language == "tr" {
            let d = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults], attributeOptions: [])
            dictation = d; speech = nil; module = d
        } else {
            let s = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
                                      attributeOptions: [])
            speech = s; dictation = nil; module = s
        }
        analyzer = SpeechAnalyzer(modules: [module],
                                  options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
    }

    static let pcm8k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    /// Harness switch: false = ask for the analyzer's own preferred format, which exercises the
    /// 8 kHz -> N kHz AVAudioConverter path (the phone may not accept 8 kHz directly).
    nonisolated(unsafe) static var considerNaturalFormat = true

    func prepare() async throws {
        if format == nil {
            format = Self.considerNaturalFormat
                ? await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: Self.pcm8k)
                : await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        }
        try await analyzer.prepareToAnalyze(in: format)
        // Vocabulary hints for ham radio.
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = ["QSO", "QSL", "QRZ", "QTH", "73", "DMR", "BrandMeister", "talkgroup",
                                           "Kilo", "Juliet", "Papa", "Charlie", "Hotel", "Echo", "Whiskey", "Yankee",
                                           "copy", "over", "roger"]
        try? await analyzer.setContext(ctx)
    }

    /// (text, isFinal) stream, same shape for both transcribers.
    func results() -> AsyncThrowingStream<(String, Bool), Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if let s = speech {
                        for try await r in s.results { cont.yield((String(r.text.characters), r.isFinal)) }
                    } else if let d = dictation {
                        for try await r in d.results { cont.yield((String(r.text.characters), r.isFinal)) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Session (one received transmission)

@available(iOS 26.0, macOS 26.0, *)
actor SubtitleSession {
    let key: String
    let src: UInt32
    let dst: UInt32
    let language: String
    private let rec: SubtitleRecognizer
    private let translator: SubtitleTranslator?

    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var pending: [Int16] = []
    private var samplesIn = 0
    private var started = false
    private var finished = false
    private var resultsTask: Task<Void, Never>?

    private let t0 = Date()
    private var firstTextMs: Double = -1
    private var enFinal: [String] = []
    private var enRaw: [String] = []
    private var enVolatile = ""
    private var trFinal: [String?] = []
    private var trVolatile = ""
    private var trChain: Task<Void, Never>?
    private var trMs: [Double] = []
    private var volatileTask: Task<Void, Never>?
    private var volatileBusy = false
    private var volatileEpoch = 0

    static let batchSamples = 800      // 100 ms

    init(key: String, src: UInt32, dst: UInt32, recognizer: SubtitleRecognizer, translator: SubtitleTranslator?, language: String) {
        self.key = key; self.src = src; self.dst = dst
        self.rec = recognizer
        self.translator = translator
        self.language = language
    }

    func start() async {
        do {
            if rec.format == nil { try await rec.prepare() }
            let fmt = rec.format ?? SubtitleRecognizer.pcm8k
            outFormat = fmt
            if fmt != SubtitleRecognizer.pcm8k {
                converter = AVAudioConverter(from: SubtitleRecognizer.pcm8k, to: fmt)
                converter?.primeMethod = .none
            }
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            inputCont = cont
            let results = rec.results()
            resultsTask = Task { [weak self] in
                do {
                    for try await (text, isFinal) in results { await self?.onResult(text, isFinal) }
                } catch {
                    dsSubLog("results error: \(error)")
                }
            }
            try await rec.analyzer.start(inputSequence: stream)
            started = true
            dsSubLog(String(format: "begin %@ src %u dst %u, analyzer started in %.0f ms", key, src, dst, Date().timeIntervalSince(t0) * 1000))
            emit("begin")
        } catch {
            dsSubLog("begin \(key): analyzer start failed: \(error)")
            dsSubRequestSpeechAuthIfNeeded()
            DSSubtitleHub.shared.emit(["t": "error", "key": key, "error": "\(error)"])
        }
    }

    func push(_ samples: [Int16]) {
        guard started, !finished else { return }
        samplesIn += samples.count
        pending.append(contentsOf: samples)
        if pending.count >= Self.batchSamples { flush(end: false) }
    }

    private func flush(end: Bool) {
        guard let cont = inputCont, let fmt = outFormat else { return }
        if pending.isEmpty && !end { return }
        let n = pending.count
        var inBuf: AVAudioPCMBuffer? = nil
        if n > 0, let b = AVAudioPCMBuffer(pcmFormat: SubtitleRecognizer.pcm8k, frameCapacity: AVAudioFrameCount(n)) {
            b.frameLength = AVAudioFrameCount(n)
            pending.withUnsafeBufferPointer { p in b.int16ChannelData![0].update(from: p.baseAddress!, count: n) }
            inBuf = b
        }
        pending.removeAll(keepingCapacity: true)
        guard let conv = converter else {
            if let b = inBuf { cont.yield(AnalyzerInput(buffer: b)) }
            return
        }
        let cap = AVAudioFrameCount(Double(max(n, 160)) * fmt.sampleRate / 8000.0) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        let st = conv.convert(to: out, error: &err) { _, status in
            if !given, let b = inBuf {
                given = true
                status.pointee = .haveData
                return b
            }
            status.pointee = end ? .endOfStream : .noDataNow
            return nil
        }
        if st == .error { dsSubLog("convert error: \(String(describing: err))"); return }
        if out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async {
        guard !finished else { return }
        finished = true
        let tEnd = Date()
        if started {
            flush(end: true)
            inputCont?.finish()
            do {
                try await rec.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                dsSubLog("finalize \(key) failed: \(error)")
            }
            await resultsTask?.value
        }
        volatileTask?.cancel()
        // A volatile tail that never became final still counts.
        if !enVolatile.isEmpty {
            addFinal(enVolatile)
            enVolatile = ""
        }
        let finalizeMs = Date().timeIntervalSince(tEnd) * 1000
        // Wait for the translation chain, bounded.
        let deadline = Date().addingTimeInterval(8)
        while trFinal.contains(where: { $0 == nil }) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        trVolatile = ""
        let audioS = Double(samplesIn) / 8000.0
        let en = enFinal.joined(separator: " ")
        let tr = trFinal.compactMap { $0 }.joined(separator: " ")
        dsSubLog(String(format: "end %@: audio %.1f s, first text %.0f ms, finalize %.0f ms, translations %@ ms",
                        key, audioS, firstTextMs, finalizeMs, trMs.map { String(format: "%.0f", $0) }.joined(separator: "/")))
        dsSubLog("final EN: \(en)")
        if !tr.isEmpty { dsSubLog("final TR: \(tr)") }
        var d = payload("final")
        d["audio"] = audioS
        d["firstMs"] = firstTextMs
        d["finalizeMs"] = finalizeMs
        d["trMs"] = trMs
        d["en"] = language == "tr" ? "" : en
        d["tr"] = language == "tr" ? en : tr
        d["enV"] = ""
        d["trV"] = ""
        d["raw"] = enRaw.joined(separator: " ")
        DSSubtitleHub.shared.emit(d)
    }

    // MARK: Results

    private func onResult(_ raw: String, _ isFinal: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if firstTextMs < 0, !text.isEmpty {
            firstTextMs = Date().timeIntervalSince(t0) * 1000
            dsSubLog(String(format: "%@: first text after %.0f ms (%.1f s audio)", key, firstTextMs, Double(samplesIn) / 8000.0))
        }
        if isFinal {
            enVolatile = ""
            trVolatile = ""
            volatileEpoch += 1          // a late volatile translation must not overwrite the final
            if !text.isEmpty { addFinal(text) }
        } else {
            enVolatile = clean(text)
            scheduleVolatileTranslation()
        }
        emit("partial")
    }

    private func clean(_ s: String) -> String {
        language == "tr" ? SubtitleGlossary.collapseCallsigns(s) : SubtitleGlossary.cleanEnglish(s)
    }

    private func addFinal(_ raw: String) {
        let en = clean(raw)
        guard !en.isEmpty else { return }
        enRaw.append(raw)
        enFinal.append(en)
        guard let tr = translator else { return }
        let idx = trFinal.count
        trFinal.append(nil)
        let prev = trChain
        trChain = Task { [weak self] in
            await prev?.value
            let t0 = Date()
            let out = await tr.translate(en)
            await self?.setTranslation(idx, out ?? "", ms: Date().timeIntervalSince(t0) * 1000)
        }
    }

    private func setTranslation(_ i: Int, _ s: String, ms: Double) {
        guard i < trFinal.count else { return }
        trFinal[i] = s
        trMs.append(ms)
        if !finished { emit("partial") }
    }

    /// Translates the unfinished sentence while it is being spoken: one request at a time, and
    /// when it returns, the newest volatile text is sent again (about one update per second).
    private func scheduleVolatileTranslation() {
        guard translator != nil, enVolatile.count >= 12, !volatileBusy else { return }
        startVolatileTranslation()
    }

    private func startVolatileTranslation() {
        guard let tr = translator, !finished else { return }
        var snapshot = enVolatile
        if snapshot.count > 240 {       // long run-on over: only the tail
            let tail = snapshot.suffix(240)
            snapshot = tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? String(tail)
        }
        let epoch = volatileEpoch
        volatileBusy = true
        volatileTask = Task { [weak self] in
            let out = await tr.translate(snapshot)
            await self?.setVolatileTranslation(snapshot, out, epoch: epoch)
        }
    }

    private func setVolatileTranslation(_ en: String, _ tr: String?, epoch: Int) {
        volatileBusy = false
        guard !finished, epoch == volatileEpoch else { return }
        if let tr = tr {
            trVolatile = tr
            emit("partial")
        }
        if !enVolatile.isEmpty, !enVolatile.hasSuffix(en), enVolatile.count >= 12 {
            startVolatileTranslation()
        }
    }

    private func payload(_ type: String) -> [String: Any] {
        let en = enFinal.joined(separator: " ")
        let tr = trFinal.compactMap { $0 }.joined(separator: " ")
        if language == "tr" {
            return ["t": type, "key": key, "src": src, "dst": dst, "lang": language,
                    "en": "", "enV": "", "tr": en, "trV": enVolatile]
        }
        return ["t": type, "key": key, "src": src, "dst": dst, "lang": language,
                "en": en, "enV": enVolatile, "tr": tr, "trV": trVolatile]
    }

    private func emit(_ type: String) { DSSubtitleHub.shared.emit(payload(type)) }
}

// MARK: - Translator

@available(iOS 26.0, macOS 26.0, *)
actor SubtitleTranslator {
    private var session: TranslationSession?
    private let en = Locale.Language(identifier: "en")
    private let tr = Locale.Language(identifier: "tr")

    /// "installed" / "supported" (pack not downloaded) / "unsupported".
    func refresh() async -> String {
        let st = await LanguageAvailability().status(from: en, to: tr)
        switch st {
        case .installed:
            if session == nil { session = TranslationSession(installedSource: en, target: tr) }
            return "installed"
        case .supported:
            // LanguageAvailability has been seen reporting .supported for an installed pair (macOS
            // command-line build), so probe: a session with installedSource throws when it is not.
            let probe = TranslationSession(installedSource: en, target: tr)
            if (try? await probe.translate("Hello.")) != nil {
                session = probe
                return "installed"
            }
            session = nil
            return "supported"
        case .unsupported:
            session = nil
            return "unsupported"
        @unknown default:
            session = nil
            return "unknown"
        }
    }

    func translate(_ english: String) async -> String? {
        guard let s = session else { return nil }
        let p = SubtitleGlossary.prepareForTranslation(english)
        if SubtitleGlossary.isOnlyClosing(p) { return SubtitleGlossary.finishTranslation("", p) }
        do {
            let r = try await s.translate(p.text)
            return SubtitleGlossary.finishTranslation(r.targetText, p)
        } catch {
            dsSubLog("translate failed: \(error)")
            return nil
        }
    }
}

// MARK: - C bridge (called from subtitles.cpp)

@_cdecl("ds_subtitle_supported")
public func ds_subtitle_supported() -> Int32 { DSSubtitleHub.isSupported ? 1 : 0 }

@_cdecl("ds_subtitle_set_callback")
public func ds_subtitle_set_callback(_ cb: DSSubtitleCallback?) { DSSubtitleHub.shared.setCallback(cb) }

@_cdecl("ds_subtitle_configure")
public func ds_subtitle_configure(_ enabled: Int32, _ translate: Int32, _ language: UnsafePointer<CChar>?) {
    let lang = language.map { String(cString: $0) } ?? "en"
    DSSubtitleHub.shared.send(.configure(enabled: enabled != 0, translate: translate != 0, language: lang))
}

@_cdecl("ds_subtitle_refresh_status")
public func ds_subtitle_refresh_status() { DSSubtitleHub.shared.send(.refreshStatus) }

@_cdecl("ds_subtitle_begin")
public func ds_subtitle_begin(_ src: UInt32, _ dst: UInt32, _ key: UnsafePointer<CChar>?) {
    DSSubtitleHub.shared.send(.begin(src: src, dst: dst, key: key.map { String(cString: $0) } ?? ""))
}

@_cdecl("ds_subtitle_push_pcm")
public func ds_subtitle_push_pcm(_ pcm: UnsafePointer<Int16>?, _ n: Int32) {
    guard let pcm = pcm, n > 0 else { return }
    DSSubtitleHub.shared.send(.pcm(Array(UnsafeBufferPointer(start: pcm, count: Int(n)))))
}

@_cdecl("ds_subtitle_end")
public func ds_subtitle_end() { DSSubtitleHub.shared.send(.end) }
