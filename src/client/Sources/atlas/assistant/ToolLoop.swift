import Foundation

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

        let engine = ConversationEngine(
            ollama: ollama,
            toolServer: toolServer,
            onToolBatch: { [weak self] _ in
                guard let self else {
                    return
                }
                await self.playToolCue(for: turnID)
            }
        )

        let result = try await engine.respond(
            to: userText,
            history: snapshot,
            activeReminderText: activeReminder?.text,
            speakerInstruction: speakerInstruction
        )

        try Task.checkCancellation()

        if result.successfulToolNames.contains(
            "acknowledge_reminder"
        ) {
            await notificationCoordinator?
                .markReminderAcknowledged()
        }

        let accumulator = SentenceAccumulator()

        for sentence in accumulator.append(result.reply) {
            try Task.checkCancellation()
            try await onSentence(sentence)
        }

        if let remaining = accumulator.finish() {
            try Task.checkCancellation()
            try await onSentence(remaining)
        }

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
