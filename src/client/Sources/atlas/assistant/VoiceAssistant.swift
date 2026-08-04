import AVFoundation
import Foundation
import QuartzCore

final class VoiceAssistant {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    let lock = NSRecursiveLock()

    private let ttsQueue = DispatchQueue(
        label: "atlas.tts",
        qos: .userInitiated
    )
    private let lifecycleQueue = DispatchQueue(
        label: "atlas.lifecycle",
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
    private let speakerClient = SpeakerClient()

    private var playback: AudioPlayback!
    var notificationCoordinator: NotificationCoordinator?

    private var state: AssistantState = .listening
    private var recording = Data()
    private var recordingSampleRate: Double = 48_000
    private let soundEffects = SoundEffects()

    private var preRollBuffers = [Data]()
    private var preRollBytes = 0

    private var speechFrames = 0
    private var silenceFrames = 0
    private var queuedAudioBuffers = 0

    private var conversationActive = false
    private var conversationTimeoutWorkItem: DispatchWorkItem?
    private var shouldEndConversationAfterSpeech = false

    private var activeTurnID: UUID?
    private var activeTurnText: String?
    private var activeTurnSpeaker: SpeakerIdentity?
    private var generationTask: Task<Void, Never>?
    private var currentPlaybackPurpose: PlaybackPurpose?
    private var pendingMergedText: String?
    private var lastThinkingFiller: String?

    var history = [
        Message(role: "system", content: SystemPrompts.mainSystemPrompt)
    ]

    init() throws {
        kokoro = try KokoroWorker()

        playback = AudioPlayback(
            player: player,
            kokoro: kokoro,
            queue: ttsQueue,
            voiceFormat: voiceFormat,
            beginSpeaking: { [weak self] purpose in
                self?.beginPlayback(purpose: purpose) ?? false
            },
            finishSpeaking: { [weak self] purpose in
                self?.bufferFinished(purpose: purpose)
            },
            beginScheduledSpeech: { [weak self] in
                self?.beginScheduledSpeech() ?? false
            },
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
            pollInterval: Config.speechPollIntervalSeconds,
            repeatInterval: Config.reminderRepeatIntervalSeconds,
            deliveryContext: { [weak self] in
                self?.scheduledSpeechDeliveryContext()
            },
            deliver: { [weak self] speech, number, wasConversationActive, onStarted in
                guard let self else {
                    return .notStarted
                }

                let spokenText = try await self.ollama.generateScheduledSpeech(
                    text: speech.text,
                    kind: speech.kind,
                    announcementNumber: number,
                    isConversationInterruption: wasConversationActive
                )

                guard !spokenText.isEmpty else {
                    return .failed
                }

                let effectName: String
                switch speech.kind {
                case .reminder:
                    effectName = "reminder"
                case .announcement:
                    effectName = "announcement"
                }
                self.soundEffects.play(effectName)

                return try await self.playback.speakScheduled(
                    spokenText,
                    onStarted: { [weak self] in
                        guard let self else {
                            return
                        }

                        print(
                            "\n[\(speech.kind.rawValue) \(number)] "
                                + speech.text
                        )
                        print("Atlas: \(spokenText)")
                        fflush(stdout)

                        if speech.kind == .reminder,
                            !wasConversationActive
                        {
                            self.beginReminderConversation()
                        }

                        await onStarted()
                    }
                )
            }
        )

        Task {
            await notificationCoordinator?.start()
        }
    }

    private func scheduledSpeechDeliveryContext() -> Bool? {
        lock.withLock {
            guard state == .listening else {
                return nil
            }

            guard queuedAudioBuffers == 0 else {
                return nil
            }

            return conversationActive
        }
    }

    private func beginPlayback(
        purpose: PlaybackPurpose
    ) -> Bool {
        var shouldCancelTimeout = false

        let didBegin = lock.withLock { () -> Bool in
            switch state {
            case .recording:
                return false

            case .listening, .processing, .speaking:
                break
            }

            state = .speaking
            currentPlaybackPurpose = purpose
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

    private func beginScheduledSpeech() -> Bool {
        var shouldCancelTimeout = false

        let didBegin = lock.withLock { () -> Bool in
            guard state == .listening else {
                return false
            }

            guard queuedAudioBuffers == 0 else {
                return false
            }

            state = .speaking
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers = 1

            shouldCancelTimeout = conversationActive
            return true
        }

        if shouldCancelTimeout {
            cancelConversationTimeout()
        }

        return didBegin
    }

    private func bufferFinished(
        purpose: PlaybackPurpose
    ) {
        var shouldStartTimeout = false
        var shouldEndConversation = false

        lock.withLock {
            queuedAudioBuffers = max(0, queuedAudioBuffers - 1)

            guard queuedAudioBuffers == 0 else {
                return
            }

            currentPlaybackPurpose = nil

            if purpose == .thinkingFiller {
                state = .listening
                speechFrames = 0
                silenceFrames = 0
                return
            }

            guard state == .speaking else {
                return
            }

            state = .listening
            speechFrames = 0
            silenceFrames = 0

            if shouldEndConversationAfterSpeech {
                shouldEndConversationAfterSpeech = false
                shouldEndConversation = true
            } else {
                shouldStartTimeout = conversationActive
            }
        }

        if shouldEndConversation {
            lifecycleQueue.async { [weak self] in
                self?.endConversation()
            }
        } else if shouldStartTimeout {
            lifecycleQueue.async { [weak self] in
                self?.resetConversationTimeout()
            }
        }
    }

    private func handleAudio(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData,
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

        guard lock.try() else {
            return
        }

        defer {
            lock.unlock()
        }

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
                let mergeIntoPendingTurn =
                    currentPlaybackPurpose == .thinkingFiller

                if mergeIntoPendingTurn {
                    pendingMergedText = activeTurnText
                } else {
                    pendingMergedText = nil
                }

                generationTask?.cancel()
                activeTurnID = nil
                activeTurnText = nil
                activeTurnSpeaker = nil
                currentPlaybackPurpose = nil

                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0
                speechFrames = 0
                clearPreRoll()
                shouldStopPlayback = true
                shouldEndConversationAfterSpeech = false
            }

        case .processing:
            break
        }

        if shouldCancelTimeout {
            cancelConversationTimeout()
        }

        if shouldStopPlayback {
            ttsQueue.async { [weak self] in
                guard let self else {
                    return
                }

                self.cancelConversationTimeout()
                self.player.stop()

                self.lock.withLock {
                    self.queuedAudioBuffers = 0
                    self.currentPlaybackPurpose = nil
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

    private func finishGeneration(
        for turnID: UUID
    ) {
        lock.withLock {
            guard activeTurnID == turnID else {
                return
            }
            generationTask = nil
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

            // Start both the STT and speaker identification tasks concurrently
            async let transcriptTask = timed("STT") {
                try await whisper.transcribe(wavURL)
            }
            async let speakerResponseTask = timed("Speaker ID") {
                try await speakerClient.identify(wavURL)
            }
            let transcript = try await transcriptTask

            guard !transcript.isEmpty else {
                print("\nNo speech recognized.")
                transitionToListening()
                return
            }

            let active = lock.withLock { conversationActive }
            let mergedPrefix = lock.withLock { () -> String? in
                let value = pendingMergedText
                pendingMergedText = nil
                return value
            }

            var userText = transcript

            if let mergedPrefix, !mergedPrefix.isEmpty {
                userText = "\(mergedPrefix) \(transcript)"
            }

            let startedNewConversation = !active
            let wakeRemainder = textAfterWakeGreeting(transcript)
            let wakeOnly =
                startedNewConversation
                && isWakeGreeting(transcript)
                && normalizedText(wakeRemainder).isEmpty

            if !active {
                guard isWakeGreeting(transcript) else {
                    print("\nIgnoring: \(transcript)")
                    transitionToListening()
                    return
                }

                beginConversation()

                userText = wakeRemainder

                if normalizedText(userText).isEmpty {
                    userText = "Hello"
                }
            } else {
                cancelConversationTimeout()
            }

            let speakerIdentity = try? await speakerResponseTask.identity
            if let speakerIdentity {
                print(
                    "[speaker] known: \(speakerIdentity.displayName) "
                        + "(similarity=\(String(format: "%.3f", speakerIdentity.similarity))))"
                )
            } else {
                print("[speaker] unknown or unavailable")
            }

            let activeReminder = await notificationCoordinator?
                .acknowledgementEligibleReminderSnapshot()

            if activeReminder == nil,
                ConversationClosing.shouldClose(
                    userText: userText,
                    normalizedText: normalizedText
                )
            {
                try await closeConversation(speaker: speakerIdentity)
                return
            }

            let turnID = UUID()
            lock.withLock {
                activeTurnID = turnID
                activeTurnText = userText
                activeTurnSpeaker = speakerIdentity
            }

            if speakerIdentity == nil {
                print("\nYou: \(userText)")
            } else {
                print(
                    "\n\(speakerIdentity!.displayName): \(userText)"
                )
            }
            print("Atlas: ", terminator: "")
            fflush(stdout)

            if !wakeOnly {
                let filler = nextThinkingFiller()

                Task { [weak self] in
                    guard let self else {
                        return
                    }

                    try? await self.playback.queueThinkingFiller(
                        filler,
                        for: turnID,
                        isCurrentTurn: { [weak self] id in
                            self?.isCurrentTurn(id) ?? false
                        }
                    )
                }
            }

            let task = Task { [weak self] in
                guard let self else {
                    return
                }
                defer {
                    self.finishGeneration(for: turnID)
                }

                let startedAt = CACurrentMediaTime()
                var printedAnyText = false

                do {
                    let fullReply = try await self.streamOllama(
                        userText,
                        turnID: turnID,
                        speakerInstruction: speakerIdentity.map {
                            self.speakerContextInstruction(for: $0)
                        } ?? nil
                    ) { [weak self] sentence in
                        guard let self else {
                            return
                        }

                        try Task.checkCancellation()

                        guard self.isCurrentTurn(turnID) else {
                            throw CancellationError()
                        }

                        if printedAnyText {
                            print(" ", terminator: "")
                        }

                        print(sentence, terminator: "")
                        fflush(stdout)
                        printedAnyText = true

                        try await self.playback.queueAssistantReply(
                            sentence,
                            for: turnID,
                            isCurrentTurn: { [weak self] id in
                                self?.isCurrentTurn(id) ?? false
                            }
                        )
                    }

                    try Task.checkCancellation()

                    guard self.isCurrentTurn(turnID) else {
                        return
                    }

                    if !printedAnyText, !fullReply.isEmpty {
                        print(fullReply, terminator: "")
                        fflush(stdout)

                        try await self.playback.queueAssistantReply(
                            fullReply,
                            for: turnID,
                            isCurrentTurn: { [weak self] id in
                                self?.isCurrentTurn(id) ?? false
                            }
                        )
                    }

                    let elapsed = CACurrentMediaTime() - startedAt

                    print()
                    print(
                        "[timing] LLM stream complete: "
                            + "\(String(format: "%.3f", elapsed)) s\n"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentTurn(turnID) else {
                        return
                    }

                    print(
                        "\n[pipeline error] "
                            + error.localizedDescription
                    )

                    self.transitionToListening()
                }
            }

            lock.withLock {
                generationTask?.cancel()
                guard activeTurnID == turnID else {
                    task.cancel()
                    return
                }
                generationTask = task
            }
        } catch {
            let nsError = error as NSError

            print(
                """

                [pipeline error]
                type: \(String(reflecting: type(of: error)))
                domain: \(nsError.domain)
                code: \(nsError.code)
                description: \(nsError.localizedDescription)
                userInfo: \(nsError.userInfo)
                """
            )

            transitionToListening()
        }
    }

    private func speakerContextInstruction(
        for speaker: SpeakerIdentity?
    ) -> String? {
        guard let speaker else {
            return nil
        }
        return SystemPrompts.speakerContextInstruction
            .replacingOccurrences(
                of: "{SPEAKER_NAME}",
                with: speaker.displayName
            )
    }

    private func speakerFarewellInstruction(
        for speaker: SpeakerIdentity?
    ) -> String? {
        guard let speaker else {
            return nil
        }

        return SystemPrompts.speakerFarewellInstruction
            .replacingOccurrences(
                of: "{SPEAKER_NAME}",
                with: speaker.displayName
            )
    }

    private func closeConversation(
        speaker: SpeakerIdentity? = nil
    ) async throws {
        let farewellInstruction = speakerFarewellInstruction(
            for: speaker
        )

        let farewell = try await ollama.generateFarewell(
            speakerInstruction: farewellInstruction
        )

        guard !farewell.isEmpty else {
            endConversation()
            return
        }

        print("\nYou: conversation closing")
        print("Atlas: \(farewell)")
        fflush(stdout)

        let turnID = UUID()

        lock.withLock {
            activeTurnID = turnID
            activeTurnText = nil
            activeTurnSpeaker = speaker
        }

        scheduleConversationEndAfterSpeech()

        try await playback.queueAssistantReply(
            farewell,
            for: turnID,
            isCurrentTurn: { [weak self] id in
                self?.isCurrentTurn(id) ?? false
            }
        )
    }

    private func beginConversation() {
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]
        }
        soundEffects.play("startup")
        print("\nAtlas is listening.")
    }

    private func beginReminderConversation() {
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]
        }

        print("\nAtlas is listening for your reminder response.")
        resetConversationTimeout()
    }

    private func scheduleConversationEndAfterSpeech() {
        lock.withLock {
            shouldEndConversationAfterSpeech = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil
        }
    }

    private func resetConversationTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.endConversation()
        }

        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = workItem
        }

        lifecycleQueue.asyncAfter(
            deadline: .now() + Config.conversationTimeoutSeconds,
            execute: workItem
        )
    }

    private func endConversation() {
        let didEnd = lock.withLock { () -> Bool in
            guard conversationActive else {
                return false
            }

            shouldEndConversationAfterSpeech = false
            conversationActive = false
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]

            generationTask?.cancel()
            generationTask = nil
            activeTurnID = nil
            activeTurnText = nil
            activeTurnSpeaker = nil
            pendingMergedText = nil
            currentPlaybackPurpose = nil

            return true
        }

        if didEnd {
            soundEffects.play("shutdown")
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
            shouldEndConversationAfterSpeech = false
            state = .listening
            recording = Data()
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers = 0
            generationTask?.cancel()
            generationTask = nil
            activeTurnID = nil
            activeTurnText = nil
            pendingMergedText = nil
            currentPlaybackPurpose = nil
            activeTurnSpeaker = nil
            clearPreRoll()
        }
    }

    private func isWakeGreeting(_ transcript: String) -> Bool {
        let words = normalizedText(transcript)
            .split(separator: " ")
            .map(String.init)

        guard !words.isEmpty else {
            return false
        }

        let wakeNames: Set<String> = ["atlas", "alice"]
        let greetings = Set(Config.wakeGreetings)

        if wakeNames.contains(words[0]) {
            return true
        }

        if words.count >= 2,
            greetings.contains(words[0]),
            wakeNames.contains(words[1])
        {
            return true
        }

        return words.count >= 3
            && words[0] == "good"
            && ["morning", "afternoon", "evening"].contains(words[1])
            && wakeNames.contains(words[2])
    }

    private func textAfterWakeGreeting(_ transcript: String) -> String {
        let words = normalizedText(transcript)
            .split(separator: " ")
            .map(String.init)

        guard !words.isEmpty else {
            return ""
        }

        let wakeNames: Set<String> = ["atlas", "alice"]
        let greetings = Set(Config.wakeGreetings)

        var wakeNameIndex: Int?

        if wakeNames.contains(words[0]) {
            wakeNameIndex = 0
        } else if words.count >= 2,
            greetings.contains(words[0]),
            wakeNames.contains(words[1])
        {
            wakeNameIndex = 1
        } else if words.count >= 3,
            words[0] == "good",
            ["morning", "afternoon", "evening"].contains(words[1]),
            wakeNames.contains(words[2])
        {
            wakeNameIndex = 2
        }

        guard let wakeNameIndex else {
            return transcript
        }

        return
            words
            .dropFirst(wakeNameIndex + 1)
            .joined(separator: " ")
    }

    func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "‘", with: "")
            .replacingOccurrences(of: "ʼ", with: "")
            .replacingOccurrences(of: "＇", with: "")
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

    internal func isCurrentTurn(_ turnID: UUID) -> Bool {
        lock.withLock {
            activeTurnID == turnID
        }
    }

    private func nextThinkingFiller() -> String {
        lock.withLock {
            let choices = Config.thinkingFillers.filter {
                $0 != lastThinkingFiller
            }

            let filler =
                (choices.isEmpty
                ? Config.thinkingFillers
                : choices).randomElement()!

            lastThinkingFiller = filler
            return filler
        }
    }

    func playToolCue(
        for turnID: UUID
    ) async {
        guard isCurrentTurn(turnID) else {
            return
        }
        soundEffects.play("tool_call")
    }
}
