import Foundation

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        turnID: UUID,
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
            activeReminderText: activeReminder?.text
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

            history = result.finalMessages

            if history.count > Config.maxHistoryMessages + 1 {
                history.removeSubrange(
                    1..<(history.count - Config.maxHistoryMessages)
                )
            }
        }

        return result.reply
    }
}
