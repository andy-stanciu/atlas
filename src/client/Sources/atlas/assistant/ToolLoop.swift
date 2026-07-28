import Foundation

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let mayRequireTool = mayRequireLightTool(userText)

        var messages = lock.withLock { () -> [Message] in
            var updated = history

            if mayRequireTool {
                updated.append(
                    Message(
                        role: "system",
                        content: """
                            This turn requires tool use. Your next response must contain
                            tool_calls only, with no user-facing prose, until successful
                            tool results have been provided.
                            """
                    )
                )
            }

            updated.append(
                Message(role: "user", content: userText)
            )

            history = updated
            return updated
        }

        let tools = try await toolServer.availableTools()
        var executedTool = false
        var retriedMissingToolCall = false

        for _ in 0..<Config.maxToolLoopSteps {
            let assistantMessage = try await ollama.chat(
                messages: messages,
                tools: tools
            )

            let toolCalls = assistantMessage.toolCalls ?? []

            messages.append(
                Message(
                    role: "assistant",
                    content: assistantMessage.content,
                    toolCalls: toolCalls
                )
            )

            if !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    executedTool = true

                    let result = try await toolServer.runTool(toolCall)

                    print(
                        "\n[tool result] \(toolCall.function.name): "
                            + result
                    )

                    messages.append(
                        Message(role: "tool", content: result)
                    )
                }

                continue
            }

            if mayRequireTool && !executedTool {
                if retriedMissingToolCall {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedMissingToolCall = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                            Validation failure: you answered a request that needs tool use
                            without invoking a tool. Do not write a natural-language answer
                            yet. Invoke the necessary tool or tools now.
                            """
                    )
                )

                continue
            }

            let reply = assistantMessage.content
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            let accumulator = SentenceAccumulator()

            for sentence in accumulator.append(reply) {
                try await onSentence(sentence)
            }

            if let remaining = accumulator.finish() {
                try await onSentence(remaining)
            }

            lock.withLock {
                history = messages

                if history.count > Config.maxHistoryMessages + 1 {
                    history.removeSubrange(
                        1..<(history.count - Config.maxHistoryMessages)
                    )
                }
            }

            return reply
        }

        throw NSError(
            domain: "Ollama",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tool loop exceeded its maximum number of steps."
            ]
        )
    }

    private func mayRequireLightTool(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let lightWords = [
            "light",
            "lights",
            "lamp",
            "lamps",
        ]

        let actionWords = [
            "on",
            "off",
            "turn",
            "switch",
            "set",
            "status",
            "check",
            "are",
            "is",
            "whether",
        ]

        return lightWords.contains { normalized.contains($0) }
            && actionWords.contains { normalized.contains($0) }
    }
}