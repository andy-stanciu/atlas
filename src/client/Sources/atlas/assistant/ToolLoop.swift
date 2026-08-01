import Foundation

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let activeReminder = await notificationCoordinator?
            .acknowledgementEligibleReminderSnapshot()

        var messages = lock.withLock { () -> [Message] in
            var updated = history

            if let activeReminder {
                updated.append(
                    Message(
                        role: "system",
                        content: SystemPrompts.activeReminderResponseInstruction
                    )
                )

                updated.append(
                    Message(
                        role: "system",
                        content: """
                            Active reminder text:
                            \(activeReminder.text)
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

        var activeReminderAcknowledged = false
        var retriedReminderAcknowledgement = false

        for step in 0..<Config.maxToolLoopSteps {
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
                print("\n[tool loop] step \(step + 1)")
                print(
                    "[tool loop] tool calls: "
                        + String(
                            describing: toolCalls.map {
                                $0.function.name
                            })
                )
                fflush(stdout)

                for toolCall in toolCalls {
                    let result = try await toolServer.runTool(toolCall)

                    print(
                        "[tool result] \(toolCall.function.name): "
                            + result
                    )

                    let succeeded =
                        (try? JSONDecoder().decode(
                            ToolSuccessResponse.self,
                            from: Data(result.utf8)
                        ))?.ok == true

                    if succeeded,
                        toolCall.function.name == "acknowledge_reminder"
                    {
                        activeReminderAcknowledged = true

                        await notificationCoordinator?
                            .markReminderAcknowledged()
                    }

                    messages.append(
                        Message(role: "tool", content: result)
                    )
                }

                continue
            }

            let reply = assistantMessage.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if reply.isEmpty {
                print(
                    """
                    \n[tool loop] rejected empty final response.
                    active reminder: \(activeReminder != nil)
                    """
                )
                fflush(stdout)

                if activeReminder != nil,
                    !activeReminderAcknowledged
                {
                    messages.append(
                        Message(
                            role: "user",
                            content: """
                                You returned neither a tool call nor spoken text.

                                The user replied to an active reminder. If their reply acknowledges
                                the reminder, call acknowledge_reminder now. Otherwise give one short
                                spoken response and keep the reminder active.
                                """
                        )
                    )
                } else {
                    messages.append(
                        Message(
                            role: "user",
                            content: """
                                You returned neither a tool call nor spoken text. Reply with one short,
                                natural spoken response to the user now.
                                """
                        )
                    )
                }

                continue
            }

            if activeReminder != nil,
                !activeReminderAcknowledged,
                claimsReminderAcknowledgement(reply)
            {
                print(
                    """
                    \n[tool loop] reminder acknowledgement validation rejected:
                    \(reply)
                    """
                )
                fflush(stdout)

                if retriedReminderAcknowledgement {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedReminderAcknowledgement = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                            Validation failure: you said the active reminder was marked
                            complete, dismissed, or acknowledged, but no successful
                            acknowledge_reminder tool call occurred.

                            Do not claim completion unless acknowledge_reminder succeeds.
                            If the user acknowledged the reminder, call
                            acknowledge_reminder now. Otherwise answer naturally without
                            claiming that the reminder was completed.
                            """
                    )
                )

                continue
            }

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

    private func claimsReminderAcknowledgement(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        return [
            "has been marked complete",
            "is marked complete",
            "marked that reminder complete",
            "marked the reminder complete",
            "marked it complete",
            "reminder is complete",
            "reminder has been completed",
            "reminder has been marked complete",
            "cancelled the reminder",
            "canceled the reminder",
            "dismissed the reminder",
        ].contains(where: normalized.contains)
    }
}
