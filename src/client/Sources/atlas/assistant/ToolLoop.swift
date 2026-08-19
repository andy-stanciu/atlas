import Foundation
import QuartzCore

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        turnID: UUID,
        speakerInstruction: String? = nil,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let activeReminder = await notificationCoordinator?
            .acknowledgementEligibleReminderSnapshot()

        let snapshot = lock.withLock { history }

        let accumulator = SentenceAccumulator()

        // Sentences flush to speech as they complete, in order, without
        // blocking the LLM stream on TTS synthesis.
        var sentenceChain: Task<Void, Never> = Task {}
        func enqueueSentence(_ sentence: String) {
            let previous = sentenceChain
            sentenceChain = Task {
                await previous.value
                try? await onSentence(sentence)
            }
        }

        let engine = ConversationEngine(
            llm: llm,
            toolServer: toolServer,
            onToolBatch: { [weak self] calls in
                guard let self else {
                    return
                }
                // A pass that calls tools: drop any unflushed preamble
                // fragment so it never prepends the final answer.
                accumulator.discardPending()
                await self.playToolCue(
                    for: calls.first?.function.name,
                    turnID: turnID
                )
            },
            onTextDelta: { delta in
                for sentence in accumulator.append(delta) {
                    enqueueSentence(sentence)
                }
            }
        )

        let generationStart = CACurrentMediaTime()
        let result = try await engine.respond(
            to: userText,
            history: snapshot,
            activeReminderText: activeReminder?.text,
            speakerInstruction: speakerInstruction
        )
        Log.timing(
            "LLM complete: "
                + String(
                    format: "%.3f",
                    CACurrentMediaTime() - generationStart
                ) + "s"
        )

        try Task.checkCancellation()

        if result.successfulToolNames.contains(
            "acknowledge_reminder"
        ) {
            await notificationCoordinator?
                .markReminderAcknowledged()
        }

        if let remaining = accumulator.finish() {
            enqueueSentence(remaining)
        }

        try Task.checkCancellation()

        await sentenceChain.value

        try Task.checkCancellation()

        lock.withLock {
            guard isCurrentTurn(turnID) else {
                return
            }

            // Update history with the final messages from the conversation result,
            // filtering out any messages that contain speaker identity information.
            history = result.finalMessages.filter {
                !$0.content.contains("Speaker identity for this request is")
            }

            if history.count > Config.maxHistoryMessages + 1 {
                history.removeSubrange(
                    1..<(history.count - Config.maxHistoryMessages)
                )
            }
        }

        return result.reply
    }
}
