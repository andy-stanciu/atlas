import Foundation
import QuartzCore

extension VoiceAssistant {
    func streamLLM(
        _ userText: String,
        turnID: UUID,
        speakerInstruction: String? = nil,
        trailingInstructions: [String] = [],
        persistAssistantReply: Bool = true,
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

        let tools = try await toolsForTurn()
        let engine = ConversationEngine(
            llm: llm,
            toolServer: toolServer,
            preloadedTools: tools,
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
            speakerInstruction: speakerInstruction,
            trailingInstructions: trailingInstructions
        )
        Log.timing(
            "LLM complete: "
                + String(
                    format: "%.3f",
                    CACurrentMediaTime() - generationStart
                ) + "s"
        )

        if activeReminder != nil || !trailingInstructions.isEmpty {
            LLMPrefixStability.reset()
        }

        try Task.checkCancellation()

        if let status = addressReminderStatus(result) {
            switch status {
            case "acknowledged":
                await notificationCoordinator?.markReminderAcknowledged()
            case "still_active":
                await notificationCoordinator?.markReminderStillActive()
            default:
                break
            }
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

            var updated = result.finalMessages
            if !persistAssistantReply, updated.last?.role == "assistant" {
                updated.removeLast()
            }
            history = updated

            if history.count > Config.maxHistoryMessages + 1 {
                history.removeSubrange(
                    1..<(history.count - Config.historyTrimTarget)
                )
                LLMPrefixStability.reset()
            }
        }

        return result.reply
    }

    private func addressReminderStatus(_ result: ConversationResult) -> String? {
        struct AddressReminderResult: Decodable { let status: String? }

        for (call, resultText) in zip(result.toolCalls, result.toolResults) {
            guard call.function.name == "address_reminder",
                let data = resultText.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(AddressReminderResult.self, from: data)
            else { continue }
            return decoded.status
        }
        return nil
    }
}
