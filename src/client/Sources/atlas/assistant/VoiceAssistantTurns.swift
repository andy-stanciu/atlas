import Foundation
import QuartzCore

extension VoiceAssistant {
    func processTurn(
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

            let client = lock.withLock { sttClient }
            let feedChain = lock.withLock { recognizerFeedChain }
            await feedChain.value

            guard let client else {
                Log.blank()
                Log.system("Not connected to sttd, dropping turn.")
                transitionToListening()
                return
            }

            let transcript = try await timed("STT") {
                try await client.finish()
            }

            guard !transcript.isEmpty else {
                Log.blank()
                Log.system("No speech recognized.")
                transitionToListening()
                return
            }

            try await processRecognizedTurn(
                transcript: transcript,
                wavURL: wavURL
            )
        } catch {
            let nsError = error as NSError

            Log.system(
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

    func processRecognizedTurn(
        transcript: String,
        wavURL: URL
    ) async throws {
        Log.transcript("You: \(transcript)")

        lock.withLock { processingTurnIsLive = true }
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

        let speakerResponse: SpeakerIdentificationResponse?
        do {
            speakerResponse = try await timed("Speaker ID") {
                try await speakerClient.identify(wavURL)
            }
        } catch {
            Log.speaker("identify request failed: \(error.localizedDescription)")
            speakerResponse = nil
        }

        let speakerIdentity = speakerResponse?.identity

        if let speakerIdentity {
            Log.speaker(
                "known: \(speakerIdentity.displayName) "
                    + "(similarity=\(String(format: "%.3f", speakerIdentity.similarity)))"
            )
        } else if let speakerResponse {
            Log.speaker(
                "status=\(speakerResponse.status.rawValue) "
                    + "similarity="
                    + "\(speakerResponse.similarity.map { String(format: "%.3f", $0) } ?? "n/a") "
                    + "duration="
                    + "\(speakerResponse.durationSeconds.map { String(format: "%.2f", $0) } ?? "n/a")s"
            )
        } else {
            Log.speaker("identify unavailable this turn")
        }

        if speakerEnrollment.isAwaitingName {
            let instruction = await speakerEnrollment.resolveNameResponse(
                userText: userText
            )

            beginGenerationTurn(
                userText: userText,
                speakerIdentity: speakerIdentity,
                speakerInstruction: nil,
                trailingInstructions: [instruction],
                playThinkingFiller: false
            )

            return
        }

        async let nameRequestPending = speakerEnrollment.processTurnResult(
            speakerResponse: speakerResponse,
            wavURL: wavURL
        )
        let activeReminder = await notificationCoordinator?
            .acknowledgementEligibleReminderSnapshot()
        let evaluation = ConversationClosing.evaluate(
            userText: userText,
            normalizedText: normalizedText
        )
        let closing = startedNewConversation ? .none : evaluation.result
        let shouldRequestName = await nameRequestPending
        var acknowledgedReminder = false
        if closing != .none, activeReminder != nil {
            acknowledgedReminder =
                await notificationCoordinator?.acknowledgeActiveReminder() ?? false
        }
        if closing == .closeNow, !acknowledgedReminder {
            beginGenerationTurn(
                userText: userText,
                speakerIdentity: speakerIdentity,
                speakerInstruction: speakerIdentity.flatMap {
                    self.speakerContextInstruction(for: $0)
                },
                trailingInstructions: [SystemPrompts.farewellInstruction],
                playThinkingFiller: false,
                onCompletion: { [weak self] in
                    self?.scheduleConversationEndAfterSpeech()
                }
            )
            return
        }
        var onCompletion: (@Sendable () async -> Void)?
        var trailingInstructions: [String] = []
        let speakerInstruction = speakerIdentity.flatMap {
            self.speakerContextInstruction(for: $0)
        }
        if closing != .none {
            trailingInstructions.append(
                acknowledgedReminder
                    ? SystemPrompts.conversationClosingWithReminderInstruction
                    : SystemPrompts.conversationClosingInstruction
            )
            onCompletion = { [weak self] in
                self?.scheduleConversationEndAfterSpeech()
            }
        } else if shouldRequestName || speakerEnrollment.hasPendingNameRequest {
            onCompletion = { [weak self] in
                await self?.speakNameRequestFollowUp()
            }
        }
        let generationText = evaluation.requestRemainder ?? userText
        beginGenerationTurn(
            userText: generationText,
            speakerIdentity: speakerIdentity,
            speakerInstruction: speakerInstruction,
            trailingInstructions: trailingInstructions,
            playThinkingFiller: Config.lowLatencyMode ? false : !wakeOnly,
            onCompletion: onCompletion
        )
    }

    func processRotatedTurn(
        pcm: Data,
        sampleRate: Double,
        transcript: String
    ) async {
        let active = lock.withLock { conversationActive }
        guard !active, isWakeGreeting(transcript) else {
            return
        }

        do {
            let wavURL = try writeTemporaryWAV(
                pcm: pcm,
                sampleRate: Int(sampleRate.rounded())
            )
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            let claimed = lock.withLock { () -> Bool in
                guard state == .recording else {
                    return false
                }
                state = .processing
                recording = Data()
                speechFrames = 0
                silenceFrames = 0
                clearPreRoll()
                return true
            }
            guard claimed else {
                return
            }
            cancelRecognizerSession()

            try await processRecognizedTurn(
                transcript: transcript,
                wavURL: wavURL
            )
        } catch {
            Log.system(
                "[pipeline error] \(error.localizedDescription)"
            )
            transitionToListening()
        }
    }

    func beginGenerationTurn(
        userText: String,
        speakerIdentity: SpeakerIdentity?,
        speakerInstruction: String?,
        trailingInstructions: [String] = [],
        persistAssistantReply: Bool = true,
        playThinkingFiller: Bool,
        onCompletion: (@Sendable () async -> Void)? = nil
    ) {
        let turnID = UUID()
        lock.withLock {
            activeTurnID = turnID
            activeTurnText = userText
            activeTurnSpeaker = speakerIdentity
        }

        if playThinkingFiller {
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
            guard let self else { return }
            defer { self.finishGeneration(for: turnID) }
            var printedAnyText = false
            do {
                let fullReply = try await self.streamLLM(
                    userText,
                    turnID: turnID,
                    speakerInstruction: speakerInstruction,
                    trailingInstructions: trailingInstructions,
                    persistAssistantReply: persistAssistantReply
                ) { [weak self] sentence in
                    guard let self else {
                        return
                    }

                    try Task.checkCancellation()

                    guard self.isCurrentTurn(turnID) else {
                        throw CancellationError()
                    }

                    guard
                        let speakable = ReplyPostProcessor.process(
                            sentence, hasPriorSentence: printedAnyText)
                    else {
                        return
                    }

                    Log.transcript(
                        (printedAnyText ? " " : "Atlas: ") + speakable,
                        terminator: ""
                    )
                    printedAnyText = true

                    try await self.playback.queueAssistantReply(
                        speakable,
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
                    let speakable = ReplyPostProcessor.processReply(fullReply)
                    if !speakable.isEmpty {
                        Log.transcript(speakable, terminator: "")
                        try await self.playback.queueAssistantReply(
                            speakable,
                            for: turnID,
                            isCurrentTurn: { [weak self] id in
                                self?.isCurrentTurn(id) ?? false
                            }
                        )
                    }
                }
                if let onCompletion {
                    await onCompletion()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentTurn(turnID) else {
                    return
                }

                Log.system(
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
    }

    func speakNameRequestFollowUp() async {
        guard !hasActiveUserTurn() else {
            speakerEnrollment.rescheduleNameRequest()
            return
        }
        guard speakerEnrollment.beginNameRequest() else {
            return
        }

        // Proactive turn: no user utterance exists, so the synthetic user
        // message carries the context and the instruction rides trailing.
        beginGenerationTurn(
            userText: "(Proactive turn; the user has not spoken.)",
            speakerIdentity: nil,
            speakerInstruction: nil,
            trailingInstructions: [SystemPrompts.speakerNameRequestInstruction],
            persistAssistantReply: false,
            playThinkingFiller: false
        )
    }

    func finishGeneration(
        for turnID: UUID
    ) {
        lock.withLock {
            guard activeTurnID == turnID else {
                return
            }
            generationTask = nil
        }
    }

    func speakerContextInstruction(
        for speaker: SpeakerIdentity?
    ) -> String? {
        guard let speaker, !speaker.anonymous else {
            return nil
        }
        return SystemPrompts.speakerContextInstruction
            .replacingOccurrences(
                of: "{SPEAKER_NAME}",
                with: speaker.displayName
            )
    }
}
