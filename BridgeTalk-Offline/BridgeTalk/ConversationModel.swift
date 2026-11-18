import AVFoundation
import Combine
import Speech
import SwiftUI
import Translation

@MainActor
final class ConversationModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var direction: Direction = .automatic
    @Published var languageA = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "languageA") ?? "") ?? .chinese {
        didSet { UserDefaults.standard.set(languageA.rawValue, forKey: "languageA") }
    }
    @Published var languageB = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "languageB") ?? "") ?? .english {
        didSet { UserDefaults.standard.set(languageB.rawValue, forKey: "languageB") }
    }
    @Published var status = "首次使用请先准备语言资源"
    @Published var source = ""
    @Published var translated = ""
    @Published var candidates: [SpeechCandidate] = []
    @Published var running = false
    @Published var preparing = false
    @Published var level: Float = 0
    @Published var threshold: Double = -38
    @Published var speechRate: Double = 0.48
    @Published var voiceDescription = "优先使用所选语言已下载的高品质声音"
    @Published var configuration: TranslationSession.Configuration?
    @Published var history: [String] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var timer: Timer?
    private var gate = SilenceGate(threshold: -38)
    private var process: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var pending: SpeechCandidate?
    private var preparationStep = 0
    private var activeUtterance: AVSpeechUtterance?
    private var observers: [NSObjectProtocol] = []
    private var authorized = false

    override init() {
        super.init()
        synthesizer.delegate = self
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if name == AVAudioSession.routeChangeNotification {
                    let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                    // Our own setCategory/setActive may send category/configuration changes.
                    guard reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue ||
                          reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                }
                if name == AVAudioSession.interruptionNotification {
                    let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                    guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                Task { @MainActor in
                    guard let self, self.running || self.preparing else { return }
                    self.stop(message: "音频被打断或设备已切换，请点开始继续。")
                }
            })
        }
    }

    func start() {
        guard !running, !preparing else { return }
        guard languageA != languageB else { status = "请选择两种不同的语言。"; return }
        reset()
        running = true
        let token = generation
        status = "检查麦克风和本地识别权限…"
        startup = Task {
            let mic = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard generation == token, running else { return }
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard generation == token, running else { return }
            guard mic, speech else {
                stop(message: "需要麦克风和语音识别权限。请在 iPhone 设置中允许后，再点开始。")
                return
            }
            authorized = true
            let locales = selectedLocales(direction)
            guard locales.allSatisfy({ SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition == true }) else {
                stop(message: "所选语言的本地语音识别不可用。请准备系统资源，或换固定方向测试；不会转云端。")
                return
            }
            listen()
        }
    }

    func stop(message: String = "已暂停") {
        running = false
        preparing = false
        reset()
        status = message
    }

    private func reset() {
        generation = UUID()
        startup?.cancel(); startup = nil
        process?.cancel(); process = nil
        watchdog?.cancel(); watchdog = nil
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        configuration = nil
        pending = nil
        candidates = []
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func listen() {
        guard running, authorized else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audio.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeTalk-\(UUID().uuidString).caf")
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            recordingURL = url
            recorder = newRecorder
            newRecorder.isMeteringEnabled = true
            gate = SilenceGate(threshold: Float(threshold))
            guard newRecorder.record() else { throw BridgeError.message("麦克风录音无法启动。") }
            status = "正在听 · 说完停顿约 1 秒"
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { stop(message: error.localizedDescription) }
    }

    private func tick() {
        guard running, let recorder else { return }
        guard recorder.isRecording else { stop(message: "录音已中断，请点开始重试。"); return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (power + 60) / 60))
        switch gate.update(elapsed: recorder.currentTime, power: power) {
        case .keepRecording: break
        case .discard:
            endRecording()
            if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            recordingURL = nil
            listen()
        case .submit:
            endRecording()
            guard let url = recordingURL else { return }
            recordingURL = nil
            recognize(url)
        }
    }

    private func endRecording() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        level = 0
    }

    private func recognize(_ url: URL) {
        let token = generation
        let mode = direction
        status = "正在本地识别 · 请等译文播完再说"
        process = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            let locales = selectedLocales(mode)
            var results: [SpeechCandidate] = []
            var errors: [String] = []
            for locale in locales {
                guard !Task.isCancelled, generation == token, running else { return }
                do { results.append(try await LocalRecognizer().recognize(url: url, locale: locale)) }
                catch is CancellationError { return }
                catch { errors.append(error.localizedDescription) }
            }
            guard generation == token, running else { return }
            if mode != .automatic, let first = results.first { choose(first) }
            else if let best = CandidateRouter.pick(results) { choose(best) }
            else if !results.isEmpty {
                candidates = results
                status = errors.isEmpty ? "语言判断不确定，请选对的原句" : "部分语言识别失败，请核对候选句或切换固定方向"
            } else { stop(message: errors.first ?? "没有识别到语音，请重试。") }
        }
    }

    func choose(_ candidate: SpeechCandidate) {
        guard running else { return }
        candidates = []
        source = candidate.text
        translated = ""
        pending = candidate
        status = "正在离线翻译…"
        configure(forward: candidate.locale == languageA.speechLocale)
    }

    func skip() {
        guard running else { return }
        candidates = []
        listen()
    }

    func prepare() {
        stop()
        guard languageA != languageB else { status = "请选择两种不同的语言。"; return }
        preparing = true
        preparationStep = 0
        status = "准备 \(languageA.name) → \(languageB.name) 资源，请允许系统下载"
        configure(forward: true)
    }

    private func selectedLocales(_ direction: Direction) -> [String] {
        switch direction {
        case .first: return [languageA.speechLocale]
        case .second: return [languageB.speechLocale]
        case .automatic: return [languageA.speechLocale, languageB.speechLocale]
        }
    }

    private func configure(forward: Bool) {
        let source = Locale.Language(identifier: (forward ? languageA : languageB).translationCode)
        let target = Locale.Language(identifier: (forward ? languageB : languageA).translationCode)
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else { configuration = .init(source: source, target: target) }
        watchdog?.cancel()
        let token = generation
        let seconds: UInt64 = preparing ? 600 : 60
        watchdog = Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard generation == token else { return }
            stop(message: "翻译等待超时。请先准备语言资源，再点开始重试。")
        }
    }

    // Called only by the visible SwiftUI translationTask; sessions are never stored.
    func translate(using session: TranslationSession) async {
        let token = generation
        let isPreparation = preparing
        let step = preparationStep
        let item = pending
        guard isPreparation || (running && item != nil) else { return }
        do {
            if isPreparation {
                let availability = LanguageAvailability()
                let from = step == 0 ? languageA : languageB
                let to = step == 0 ? languageB : languageA
                let availabilityStatus = await availability.status(from: Locale.Language(identifier: from.translationCode), to: Locale.Language(identifier: to.translationCode))
                guard generation == token, preparing, !Task.isCancelled else { return }
                guard availabilityStatus != .unsupported else {
                    stop(message: "这台设备的系统翻译不支持所选语言组合，请换一组。")
                    return
                }
                try await session.prepareTranslation()
                guard generation == token, preparing, !Task.isCancelled else { return }
                watchdog?.cancel()
                if step == 0 {
                    preparationStep = 1
                    status = "准备 \(languageB.name) → \(languageA.name) 资源，请允许系统下载"
                    configure(forward: false)
                } else {
                    preparing = false
                    configuration = nil
                    UserDefaults.standard.set(true, forKey: "translationPrepared")
                    status = "翻译资源已准备。请关闭 VPN，点开始测试对话；还需确认所选语言的系统听写资源。"
                }
            } else if let item {
                let availability = LanguageAvailability()
                let from = item.locale == languageA.speechLocale ? languageA : languageB
                let to = item.locale == languageA.speechLocale ? languageB : languageA
                let installed = await availability.status(
                    from: Locale.Language(identifier: from.translationCode),
                    to: Locale.Language(identifier: to.translationCode))
                guard generation == token, running, !Task.isCancelled else { return }
                guard installed == .installed else {
                    stop(message: "翻译语言资源尚未安装或已被系统清理，请联网点准备资源。")
                    return
                }
                let response = try await session.translate(item.text)
                guard generation == token, running, !Task.isCancelled else { return }
                watchdog?.cancel()
                pending = nil
                translated = response.targetText
                history.insert("\(item.text)\n\(response.targetText)", at: 0)
                history = Array(history.prefix(20))
                speak(response.targetText, language: to.speechLocale)
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            stop(message: "翻译未完成：\(error.localizedDescription)。请联网准备资源后重试。")
        }
    }

    private func speak(_ text: String, language: String) {
        guard running else { return }
        let voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.identifier < $1.identifier
            }.first ?? AVSpeechSynthesisVoice(language: language)
        guard let voice else {
            stop(message: "译文已显示，但缺少对应朗读声音，请在系统设置下载声音。")
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(speechRate)
        voiceDescription = "当前声音：\(voice.name)（\(voice.language)）"
        activeUtterance = utterance
        status = "正在朗读 · 麦克风暂时关闭"
        synthesizer.speak(utterance)
        let token = generation
        watchdog = Task {
            do { try await Task.sleep(nanoseconds: 90_000_000_000) }
            catch { return }
            guard generation == token else { return }
            stop(message: "朗读超时，译文已保留，请点开始重试。")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.running, self.activeUtterance === utterance else { return }
            self.activeUtterance = nil
            self.watchdog?.cancel()
            let token = self.generation
            self.process = Task {
                do { try await Task.sleep(nanoseconds: 450_000_000) }
                catch { return }
                guard self.running, self.generation == token else { return }
                self.listen()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.running, self.activeUtterance === utterance else { return }
            self.stop(message: "朗读被打断，请点开始继续。")
        }
    }
}
