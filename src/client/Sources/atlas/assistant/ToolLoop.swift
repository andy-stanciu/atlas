import Foundation

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let mayRequireTool = mayRequireLightTool(userText)
        let activeReminder = await notificationCoordinator?
            .acknowledgementEligibleReminderSnapshot()

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
                            Active reminder notification ID:
                            \(activeReminder.id)

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
        var executedTool = false
        var retriedMissingToolCall = false
        var retriedDeferredAction = false
        var activeReminderAcknowledged = false

        for step in 0..<Config.maxToolLoopSteps {
            let assistantMessage = try await ollama.chat(
                messages: messages,
                tools: tools
            )

            let toolCalls: [ToolCall] = assistantMessage.toolCalls ?? []
            if !toolCalls.isEmpty {
                print("\n[tool loop] step \(step + 1)")
                print(
                    "[tool loop] tool calls: "
                        + String(
                            describing: assistantMessage.toolCalls?
                                .map({ ToolCall in ToolCall.function.name }) ?? [])
                )
                fflush(stdout)
            }

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

                    if toolCall.function.name == "acknowledge_notification" {
                        await handleReminderAcknowledgement(
                            toolCall: toolCall,
                            result: result
                        )

                        if let payload = try? JSONDecoder().decode(
                            AcknowledgementResponse.self,
                            from: Data(result.utf8)
                        ), payload.ok {
                            activeReminderAcknowledged = true
                        }
                    }

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
                print("[tool loop] required-tool validation rejected")
                print("[tool loop] reply: \(assistantMessage.content)")
                fflush(stdout)

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

            if activeReminder != nil && !activeReminderAcknowledged
                && claimsReminderAcknowledgement(reply)
            {
                print(
                    "[tool loop] validation: reminder acknowledgement "
                        + "was claimed without acknowledge_notification"
                )
                print("[tool loop] rejected reply: \(reply)")
                fflush(stdout)

                if retriedMissingToolCall {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedMissingToolCall = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                            Validation failure: you told the user that the active reminder
                            was marked complete, dismissed, or cancelled, but you did not
                            call acknowledge_notification.

                            Do not say the reminder was completed unless the tool succeeds.
                            If the user's message acknowledges the active reminder in any way,
                            call acknowledge_notification now using the exact notification
                            ID provided in the active-reminder instructions. Otherwise,
                            respond naturally without claiming that it was marked complete.
                            """
                    )
                )

                continue
            }

            if mayContainDeferredActionLanguage(reply) && mayRequireActionCompletion(userText) {
                print("[tool loop] deferred-action validation rejected: \(reply)")
                fflush(stdout)

                if retriedDeferredAction {
                    print("[tool loop] deferred-action retry already used")
                    fflush(stdout)
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedDeferredAction = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                            Validation failure: do not promise, announce, or describe a
                            pending action. If an action remains to be performed, invoke
                            its required tool now. Complete every requested action before
                            replying. If you cannot complete it because information or a
                            capability is missing, say that directly and briefly.
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

    private func handleReminderAcknowledgement(
        toolCall: ToolCall,
        result: String
    ) async {
        guard
            let notificationID = notificationID(from: toolCall),
            let payload = try? JSONDecoder().decode(
                AcknowledgementResponse.self,
                from: Data(result.utf8)
            ),
            payload.ok
        else {
            return
        }

        await notificationCoordinator?.markAcknowledged(
            notificationID: notificationID
        )
    }

    private func notificationID(
        from toolCall: ToolCall
    ) -> String? {
        guard
            case .string(let notificationID) =
                toolCall.function.arguments["notification_id"]
        else {
            return nil
        }

        return notificationID
    }

    private func mayContainDeferredActionLanguage(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let patterns = [
            #"\bi will\b"#,
            #"\bi ll\b"#,
            #"\bi need to\b"#,
            #"\bonce i have\b"#,
            #"\bnext i will\b"#,
            #"\bnow let me\b"#,
            #"\bi am going to\b"#,
        ]

        return patterns.contains { pattern in
            normalized.range(
                of: pattern,
                options: .regularExpression
            ) != nil
        }
    }

    private func mayRequireActionCompletion(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let actionPhrases = [
            "turn on",
            "turn off",
            "switch on",
            "switch off",
            "reminder",
            "schedule",
            "cancel",
            "delete",
            "dismiss",
        ]

        return actionPhrases.contains { normalized.contains($0) }
    }

    private func claimsReminderAcknowledgement(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let phrases = [
            "marked that reminder complete",
            "marked the reminder complete",
            "marked it complete",
            "reminder is complete",
            "reminder has been completed",
            "reminder has been marked complete",
            "cancelled the reminder",
            "canceled the reminder",
            "dismissed the reminder",
        ]

        return phrases.contains { normalized.contains($0) }
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
