import AVFoundation
import Foundation
import QuartzCore

final class VoiceAssistant {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let lock = NSLock()

    private let ttsQueue = DispatchQueue(
        label: "atlas.tts",
        qos: .userInitiated
    )

    private let voiceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private let kokoro: KokoroWorker
    private let whisper = WhisperClient()
    let ollama = OllamaClient()
    let toolServer = ToolServerClient()

    private var playback: AudioPlayback!
    var notificationCoordinator: NotificationCoordinator?

    private var state: AssistantState = .listening
    private var recording = Data()
    private var recordingSampleRate: Double = 48_000

    private var preRollBuffers = [Data]()
    private var preRollBytes = 0

    private var speechFrames = 0
    private var silenceFrames = 0
    private var queuedAudioBuffers = 0

    private var conversationActive = false
    private var conversationTimeoutWorkItem: DispatchWorkItem?

    var history = [
        Message(role: "system", content: Config.systemPrompt)
    ]

    init() throws {
        kokoro = try KokoroWorker()

        playback = AudioPlayback(
            player: player,
            kokoro: kokoro,
            queue: ttsQueue,
            voiceFormat: voiceFormat,
            beginSpeaking: { [weak self] in
                self?.beginPlayback() ?? false
            },
            finishSpeaking: { [weak self] in
                self?.bufferFinished()
            },
            beginReminderPlayback: { [weak self] in
                self?.beginReminderPlayback() ?? false
            }
        )
    }

    deinit {
        notificationCoordinator = nil
    }

    func start() throws {
        let input = engine.inputNode
        let output = engine.outputNode

        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)

        engine.attach(player)

        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: voiceFormat
        )

        engine.connect(
            engine.mainMixerNode,
            to: output,
            format: voiceFormat
        )

        let tapFormat = input.outputFormat(forBus: 0)

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw NSError(
                domain: "Atlas",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No valid microphone format: \(tapFormat)"
                ]
            )
        }

        recordingSampleRate = tapFormat.sampleRate
        input.removeTap(onBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.handleAudio(buffer)
        }

        engine.prepare()
        try engine.start()
        startNotificationCoordinator()

        print(
            """
            Voice-processing audio engine started.
            Say “Hey Atlas” or “Hi Atlas” to begin. Press Ctrl-C to quit.

            """
        )
    }

    private func startNotificationCoordinator() {
        notificationCoordinator = NotificationCoordinator(
            toolServer: toolServer,
            pollInterval: Config.notificationPollIntervalSeconds,
            repeatInterval: Config.reminderRepeatIntervalSeconds,
            isIdle: { [weak self] in
                self?.isAvailableForReminderDelivery() ?? false
            },
            deliver: { [weak self] notification, announcementNumber in
                guard let self else {
                    return false
                }

                let speech = try await self.ollama.generateReminderSpeech(
                    text: notification.text,
                    announcementNumber: announcementNumber
                )

                guard !speech.isEmpty else {
                    return false
                }

                print(
                    "\n[reminder \(announcementNumber)] "
                        + notification.text
                )
                print(
                    "Atlas: \(speech)"
                )
                fflush(stdout)

                let result = try await self.playback.speak(
                    speech,
                    purpose: .reminder
                )

                if result.completed {
                    self.beginReminderConversation()
                }

                return result.completed
            }
        )

        Task {
            await notificationCoordinator?.start()
        }
    }

    private func isAvailableForReminderDelivery() -> Bool {
        lock.withLock {
            state == .listening
                && queuedAudioBuffers == 0
                && !conversationActive
        }
    }

    private func beginPlayback() -> Bool {
        var shouldCancelTimeout = false

        let didBegin = lock.withLock { () -> Bool in
            switch state {
            case .listening, .processing, .speaking:
                break

            case .recording:
                return false
            }

            state = .speaking
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers += 1

            shouldCancelTimeout = conversationActive
            return true
        }

        if shouldCancelTimeout {
            cancelConversationTimeout()
        }

        return didBegin
    }

    private func beginReminderPlayback() -> Bool {
        lock.withLock {
            guard state == .listening else {
                return false
            }

            guard queuedAudioBuffers == 0 else {
                return false
            }

            guard !conversationActive else {
                return false
            }

            state = .speaking
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers = 1

            return true
        }
    }

    private func bufferFinished() {
        var shouldStartTimeout = false

        lock.withLock {
            queuedAudioBuffers = max(0, queuedAudioBuffers - 1)

            if queuedAudioBuffers == 0, state == .speaking {
                state = .listening
                speechFrames = 0
                silenceFrames = 0
                shouldStartTimeout = conversationActive
            }
        }

        if shouldStartTimeout {
            resetConversationTimeout()
        }
    }

    private func handleAudio(_ buffer: AVAudioPCMBuffer) {
        guard
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }

        let samples = channels[0]
        let count = Int(buffer.frameLength)

        let voiced =
            rms(samples, count: count) >= Config.speechThreshold
            || peak(samples, count: count) >= Config.speechPeakThreshold

        let pcm = floatToPCM16(samples, count: count)

        var completedRecording: Data?
        var completedSampleRate: Double?
        var shouldStopPlayback = false
        var shouldCancelTimeout = false

        lock.lock()

        switch state {
        case .listening:
            appendToPreRoll(pcm)
            speechFrames = voiced ? speechFrames + 1 : 0

            if speechFrames >= Config.startSpeechFrames {
                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0
                clearPreRoll()
                shouldCancelTimeout = conversationActive

                print("\nListening...", terminator: "")
                fflush(stdout)
            }

        case .recording:
            recording.append(pcm)

            if voiced {
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }

            if silenceFrames >= Config.endSilenceFrames {
                if recording.count >= Config.minimumRecordingBytes {
                    completedRecording = recording
                    completedSampleRate = recordingSampleRate
                    state = .processing
                } else {
                    state = .listening
                }

                recording = Data()
                speechFrames = 0
                silenceFrames = 0
                clearPreRoll()
            }

        case .speaking:
            appendToPreRoll(pcm)
            speechFrames = voiced ? speechFrames + 1 : 0

            if speechFrames >= Config.interruptSpeechFrames {
                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0
                speechFrames = 0
                clearPreRoll()
                shouldStopPlayback = true
            }

        case .processing:
            break
        }

        lock.unlock()

        if shouldCancelTimeout {
            cancelConversationTimeout()
        }

        if shouldStopPlayback {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.cancelConversationTimeout()
                self.player.stop()

                self.lock.withLock {
                    self.queuedAudioBuffers = 0
                }

                print("\nInterrupted. Listening...", terminator: "")
                fflush(stdout)
            }
        }

        if let completedRecording, let completedSampleRate {
            Task {
                await processTurn(
                    pcm: completedRecording,
                    sampleRate: completedSampleRate
                )
            }
        }
    }

    private func processTurn(
        pcm: Data,
        sampleRate: Double
    ) async {
        do {
            let wavURL = try writeTemporaryWAV(
                pcm: pcm,
                sampleRate: Int(sampleRate.rounded())
            )

            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            let transcript = try await timed("STT") {
                try await whisper.transcribe(wavURL)
            }

            guard !transcript.isEmpty else {
                print("\nNo speech recognized.")
                transitionToListening()
                return
            }

            let active = lock.withLock { conversationActive }
            var userText = transcript

            if !active {
                guard isWakeGreeting(transcript) else {
                    print("\nIgnoring: \(transcript)")
                    transitionToListening()
                    return
                }

                beginConversation()

                userText = textAfterWakeGreeting(transcript)

                if userText.isEmpty {
                    userText = "Hello"
                }
            } else {
                cancelConversationTimeout()
            }

            print("\nYou: \(userText)")
            print("Atlas: ", terminator: "")
            fflush(stdout)

            let startedAt = CACurrentMediaTime()
            var printedAnyText = false

            let fullReply = try await streamOllama(userText) {
                [weak self] sentence in
                guard let self else {
                    return
                }

                if printedAnyText {
                    print(" ", terminator: "")
                }

                print(sentence, terminator: "")
                fflush(stdout)
                printedAnyText = true

                try await self.playback.queueNormalSpeech(sentence)
            }

            let elapsed = CACurrentMediaTime() - startedAt

            if !printedAnyText {
                print(fullReply, terminator: "")
            }

            print()
            print(
                "[timing] LLM stream complete: "
                    + "\(String(format: "%.3f", elapsed)) s"
            )
        } catch AtlasError.toolRequiredButNotInvoked {
            let fallback =
                "Something went wrong with that request. "
                + "Please try again."

            print("\nAtlas: \(fallback)")
            try? await playback.queueNormalSpeech(fallback)
        } catch {
            print("\nPipeline error: \(error.localizedDescription)")
            transitionToListening()
        }
    }

    private func beginConversation() {
        lock.withLock {
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: Config.systemPrompt)
            ]
        }

        print("\nAtlas is listening.")
    }

    private func beginReminderConversation() {
        lock.withLock {
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: Config.systemPrompt)
            ]
        }

        print("\nAtlas is listening for your reminder response.")
        resetConversationTimeout()
    }

    private func resetConversationTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.endConversation()
        }

        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = workItem
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Config.conversationTimeoutSeconds,
            execute: workItem
        )
    }

    private func endConversation() {
        let didEnd = lock.withLock { () -> Bool in
            guard conversationActive else {
                return false
            }

            conversationActive = false
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: Config.systemPrompt)
            ]

            return true
        }

        if didEnd {
            print("\nAtlas conversation ended. Say “Hey Atlas” to start again.")
        }
    }

    private func cancelConversationTimeout() {
        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil
        }
    }

    private func transitionToListening() {
        lock.withLock {
            state = .listening
            recording = Data()
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers = 0
            clearPreRoll()
        }
    }

    private func isWakeGreeting(_ transcript: String) -> Bool {
        let text = normalizedText(transcript)

        if text == "atlas" || text.hasPrefix("atlas ") {
            return true
        }

        return Config.wakeGreetings.contains {
            text.hasPrefix("\($0) atlas")
        }
    }

    private func textAfterWakeGreeting(_ transcript: String) -> String {
        var text = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let patterns = [
            #"(?i)^\s*(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*hey\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*hi\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*hello\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*good\s+morning\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*good\s+afternoon\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*good\s+evening\s+(atlas)[\s,!.:;-]*"#,
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern
                )
            else {
                continue
            }

            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendToPreRoll(_ pcm: Data) {
        let maxBytes = Int(
            recordingSampleRate
                * Double(Config.preRollMilliseconds)
                / 1_000
                * 2
        )

        preRollBuffers.append(pcm)
        preRollBytes += pcm.count

        while preRollBytes > maxBytes, !preRollBuffers.isEmpty {
            let removed = preRollBuffers.removeFirst()
            preRollBytes -= removed.count
        }
    }

    private func joinedPreRoll() -> Data {
        preRollBuffers.reduce(into: Data()) { result, buffer in
            result.append(buffer)
        }
    }

    private func clearPreRoll() {
        preRollBuffers.removeAll(keepingCapacity: true)
        preRollBytes = 0
    }

    private func rms(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        var sum: Float = 0

        for index in 0..<count {
            sum += samples[index] * samples[index]
        }

        return sqrt(sum / Float(count))
    }

    private func peak(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        var value: Float = 0

        for index in 0..<count {
            value = max(value, abs(samples[index]))
        }

        return value
    }

    private func floatToPCM16(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Data {
        var data = Data(capacity: count * 2)

        for index in 0..<count {
            let clipped = max(-1, min(1, samples[index]))
            var value = Int16(
                clipped * Float(Int16.max)
            ).littleEndian

            withUnsafeBytes(of: &value) {
                data.append(contentsOf: $0)
            }
        }

        return data
    }

    private func timed<T>(
        _ label: String,
        _ action: () async throws -> T
    ) async rethrows -> T {
        let startedAt = CACurrentMediaTime()
        let result = try await action()
        let elapsed = CACurrentMediaTime() - startedAt

        print(
            "\n[timing] \(label): "
                + "\(String(format: "%.3f", elapsed)) s"
        )

        return result
    }
}
