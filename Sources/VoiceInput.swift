import AVFoundation
import Speech

/// 本地语音输入：用 macOS 自带的听写模型（on-device），不走网络。
/// 只做一件事 —— 把麦克风里的说话变成文字，通过闭包往外抛。
final class VoiceInput {
    /// 实时识别结果（含未定稿）
    var onPartial: ((String) -> Void)?
    /// 出错时抛一句人话
    var onError: ((String) -> Void)?
    /// 识别自己结束了（定稿 / 出错），不是外部 stop 触发的
    var onFinish: (() -> Void)?

    private(set) var isListening = false

    /// 连续多久没有任何识别结果就自动收摊（说话中途的短暂停顿不算）
    var silenceTimeout: TimeInterval = 2.5

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastActivityAt = Date.distantPast

    private static var preferredLocale: Locale {
        let current = Locale.current
        if SFSpeechRecognizer(locale: current) != nil { return current }
        return Locale(identifier: "zh-CN")
    }

    /// 先要麦克风 + 语音识别两个权限，都拿到才开始听
    func start() {
        guard !isListening else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized else {
                DispatchQueue.main.async { self.onError?(L10n.t("没拿到语音识别权限", "Speech recognition permission not granted")) }
                return
            }
            requestMicPermission { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self.onError?(L10n.t("没拿到麦克风权限", "Microphone permission not granted"))
                        return
                    }
                    self.beginSession()
                }
            }
        }
    }

    /// 麦克风权限：macOS 14+ 走 AVAudioApplication，更低版本（最低支持 13）
    /// 只能走 AVCaptureDevice —— 它申请的是同一个 TCC 麦克风权限。
    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        teardown()
    }

    // MARK: - 内部

    private func beginSession() {
        guard let recognizer = SFSpeechRecognizer(locale: Self.preferredLocale),
              recognizer.isAvailable else {
            onError?(L10n.t("这台机器的语音识别暂时不可用", "Speech recognition is unavailable on this Mac"))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 关键：只用本地模型
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onError?(L10n.t("没找到可用的麦克风", "No usable microphone found"))
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            onError?(L10n.t("麦克风打不开", "Could not start the microphone"))
            return
        }

        isListening = true
        lastActivityAt = Date()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.isListening else { return }
            if Date().timeIntervalSince(self.lastActivityAt) >= self.silenceTimeout {
                self.teardown(notify: true)   // 静音太久：自动收摊，由上层决定存不存
            }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                // 空结果（环境噪音）不算「说了话」，否则静音永远判不出来
                if !text.isEmpty { self.lastActivityAt = Date() }
                DispatchQueue.main.async { self.onPartial?(text) }
                if result.isFinal { DispatchQueue.main.async { self.teardown(notify: true) } }
            }
            if error != nil { DispatchQueue.main.async { self.teardown(notify: true) } }
        }
    }

    private func teardown(notify: Bool = false) {
        guard isListening || request != nil else { return }
        isListening = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if notify { onFinish?() }
    }
}
