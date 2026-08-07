import Foundation
import QuartzCore

extension VoiceAssistant {

    func beginPlayback(
        purpose: PlaybackPurpose
    ) -> Bool {
        var shouldCancelTimeout = false

        let didBegin = lock.withLock { () -> Bool in
            switch state {
            case .recording:
                return false

            case .listening, .processing:
                speakingStartedAt = CACurrentMediaTime()

            case .speaking:
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

    func beginScheduledSpeech() -> Bool {
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
            speakingStartedAt = CACurrentMediaTime()

            shouldCancelTimeout = conversationActive
            return true
        }

        if shouldCancelTimeout {
            cancelConversationTimeout()
        }

        return didBegin
    }

    func bufferFinished(
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
                // Not .listening — the real reply hasn't started yet
                // (generation may still be running). Staying in
                // .processing keeps scheduled speech (reminders,
                // announcements) from sneaking in during this gap.
                state = .processing
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

    func nextThinkingFiller() -> String {
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

    func startNotificationCoordinator() {
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
                return try await self.playback.speakScheduled(
                    spokenText,
                    onStarted: { [weak self] in
                        guard let self else {
                            return
                        }

                        let effectName: String
                        switch speech.kind {
                        case .reminder:
                            effectName = "reminder"
                        case .announcement:
                            effectName = "announcement"
                        }
                        self.soundEffects.play(effectName)

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

    func scheduledSpeechDeliveryContext() -> Bool? {
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
}
