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
                print("\n[stt] Not connected to sttd, dropping turn.")
                transitionToListening()
                return
            }

            let transcript = try await timed("STT") {
                try await client.finish()
            }

            guard !transcript.isEmpty else {
                consoleTranscript.clear()
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
                    consoleTranscript.clear()
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
                print("[speaker] identify request failed: \(error.localizedDescription)")
                speakerResponse = nil
            }

            let speakerIdentity = speakerResponse?.identity

            if let speakerIdentity {
                print(
                    "[speaker] known: \(speakerIdentity.displayName) "
                        + "(similarity=\(String(format: "%.3f", speakerIdentity.similarity)))"
                )
            } else if let speakerResponse {
                print(
                    "[speaker] status=\(speakerResponse.status.rawValue) "
                        + "similarity="
                        + "\(speakerResponse.similarity.map { String(format: "%.3f", $0) } ?? "n/a") "
                        + "duration="
                        + "\(speakerResponse.durationSeconds.map { String(format: "%.2f", $0) } ?? "n/a")s"
                )
            } else {
                print("[speaker] identify unavailable this turn")
            }

            if speakerEnrollment.isAwaitingName {
                let instruction = await speakerEnrollment.resolveNameResponse(
                    userText: userText
                )

                beginGenerationTurn(
                    userText: userText,
                    speakerIdentity: speakerIdentity,
                    speakerInstruction: instruction,
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
            let closing = evaluation.result
            let shouldRequestName = await nameRequestPending
            var acknowledgedReminder = false
            if closing != .none, activeReminder != nil {
                acknowledgedReminder =
                    await notificationCoordinator?.acknowledgeActiveReminder() ?? false
            }
            if closing == .closeNow, !acknowledgedReminder {
                try await closeConversation(speaker: speakerIdentity)
                return
            }
            var onCompletion: (@Sendable () async -> Void)?
            var speakerInstruction = speakerIdentity.flatMap {
                self.speakerContextInstruction(for: $0)
            }
            if closing != .none {
                let closingInstruction =
                    acknowledgedReminder
                    ? SystemPrompts.conversationClosingWithReminderInstruction
                    : SystemPrompts.conversationClosingInstruction

                speakerInstruction = [
                    speakerInstruction,
                    closingInstruction,
                ]
                .compactMap { $0 }
                .joined(separator: "\n\n")

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
                playThinkingFiller: !wakeOnly,
                onCompletion: onCompletion
            )
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

    func beginGenerationTurn(
        userText: String,
        speakerIdentity: SpeakerIdentity?,
        speakerInstruction: String?,
        playThinkingFiller: Bool,
        onCompletion: (@Sendable () async -> Void)? = nil
    ) {
        let turnID = UUID()
        lock.withLock {
            activeTurnID = turnID
            activeTurnText = userText
            activeTurnSpeaker = speakerIdentity
        }

        consoleTranscript.clear()
        print("Atlas: ", terminator: "")
        fflush(stdout)

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

            let startedAt = CACurrentMediaTime()
            var printedAnyText = false

            do {
                let fullReply = try await self.streamOllama(
                    userText,
                    turnID: turnID,
                    speakerInstruction: speakerInstruction
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

                    if printedAnyText {
                        print(" ", terminator: "")
                    }

                    print(speakable, terminator: "")
                    fflush(stdout)
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
                        print(speakable, terminator: "")
                        fflush(stdout)

                        try await self.playback.queueAssistantReply(
                            speakable,
                            for: turnID,
                            isCurrentTurn: { [weak self] id in
                                self?.isCurrentTurn(id) ?? false
                            }
                        )
                    }
                }

                let elapsed = CACurrentMediaTime() - startedAt
                print()
                print("[timing] LLM stream complete: \(String(format: "%.3f", elapsed)) s\n")

                if let onCompletion {
                    await onCompletion()
                }
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
    }

    func speakNameRequestFollowUp() async {
        guard !hasActiveUserTurn() else {
            speakerEnrollment.rescheduleNameRequest()
            return
        }
        guard let prompt = await speakerEnrollment.beginNameRequest() else {
            return
        }

        print("Atlas: \(prompt)")
        fflush(stdout)

        let turnID = UUID()
        lock.withLock {
            activeTurnID = turnID
            activeTurnText = nil
        }

        try? await playback.queueAssistantReply(
            prompt,
            for: turnID,
            isCurrentTurn: { [weak self] id in
                self?.isCurrentTurn(id) ?? false
            }
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

    func speakerFarewellInstruction(
        for speaker: SpeakerIdentity?
    ) -> String? {
        guard let speaker, !speaker.anonymous else {
            return nil
        }

        return SystemPrompts.speakerFarewellInstruction
            .replacingOccurrences(
                of: "{SPEAKER_NAME}",
                with: speaker.displayName
            )
    }

    func closeConversation(
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
}
