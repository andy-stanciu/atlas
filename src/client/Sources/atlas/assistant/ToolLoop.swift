import Foundation

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let activeReminder = await notificationCoordinator?
            .acknowledgementEligibleReminderSnapshot()

        let snapshot = lock.withLock { history }

        let engine = ConversationEngine(
            ollama: ollama,
            toolServer: toolServer
        )

        let result = try await engine.respond(
            to: userText,
            history: snapshot,
            activeReminderText: activeReminder?.text
        )

        if result.successfulToolNames.contains(
            "acknowledge_reminder"
        ) {
            await notificationCoordinator?
                .markReminderAcknowledged()
        }

        let accumulator = SentenceAccumulator()

        for sentence in accumulator.append(result.reply) {
            try await onSentence(sentence)
        }

        if let remaining = accumulator.finish() {
            try await onSentence(remaining)
        }

        lock.withLock {
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
