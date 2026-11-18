import Foundation
import Speech

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

@MainActor
final class LocalRecognizer {
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<SpeechCandidate, Error>?
    private var recognizer: SFSpeechRecognizer?

    func recognize(url: URL, locale: String) async throws -> SpeechCandidate {
        try Task.checkCancellation()
        guard let engine = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              engine.supportsOnDeviceRecognition else {
            throw BridgeError.message("\(locale) 的本地识别不可用。请先准备系统语音资源，再重试；不会改用云端。")
        }
        recognizer = engine
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                task = engine.recognitionTask(with: request) { [weak self] result, error in
                    // Extract value types before crossing into the main actor.
                    let final = result?.isFinal == true
                    let text = result?.bestTranscription.formattedString ?? ""
                    let segments = result?.bestTranscription.segments ?? []
                    let confidence = segments.isEmpty ? Float(0) : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                    let detail = error?.localizedDescription
                    Task { @MainActor in
                        guard let self else { return }
                        if final, !text.isEmpty {
                            self.finish(.success(SpeechCandidate(text: text, locale: locale, confidence: confidence)))
                        } else if let detail {
                            self.finish(.failure(BridgeError.message("本地识别失败：\(detail)")))
                        } else if final {
                            self.finish(.failure(BridgeError.message("没有识别到清晰语音。")))
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                    catch { return }
                    self?.finish(.failure(BridgeError.message("本地识别超时，请检查语言资源或缩短句子。")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<SpeechCandidate, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        recognizer = nil
        pending.resume(with: result)
    }
}
