import Foundation

private enum ToolRequirement: Hashable {
    case light
    case event
    case scheduling
}

extension VoiceAssistant {
    func streamOllama(
        _ userText: String,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let activeReminder = await notificationCoordinator?
            .acknowledgementEligibleReminderSnapshot()
        let mayRequireConversationEndTool =
            activeReminder == nil
            && mayRequireConversationEndTool(userText)
        let toolRequirements: Set<ToolRequirement> = {
            guard !mayRequireConversationEndTool || activeReminder == nil else {
                return []
            }
            var requirements = Set<ToolRequirement>()
            if mayRequireLightTool(userText) {
                requirements.insert(.light)
            }
            if mayRequireEventTool(userText) {
                requirements.insert(.event)
            }
            if mayRequireSchedulingTool(userText) {
                requirements.insert(.scheduling)
            }
            return requirements
        }()

        let mayRequireTool = !toolRequirements.isEmpty
        var messages = lock.withLock { () -> [Message] in
            var updated = history

            if mayRequireConversationEndTool {
                updated.append(
                    Message(
                        role: "system",
                        content: """
                            The user has clearly indicated that the conversation should end.
                            Your next response must contain exactly one tool call:
                            end_conversation.

                            Do not include user-facing prose. Do not call any other tool.
                            After the tool result is provided, reply with exactly one short,
                            warm farewell sentence.
                            """
                    )
                )
            } else if mayRequireTool {
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

        var tools = try await toolServer.availableTools()
        if activeReminder == nil {
            tools.append(endConversationTool)
        }

        var executedRequirements = Set<ToolRequirement>()
        var retriedRequirements = Set<ToolRequirement>()
        var retriedDeferredAction = false
        var activeReminderAcknowledged = false
        var conversationEndRequested = false
        var retriedMissingConversationEndTool = false
        var retriedReminderAcknowledgement = false

        let toolRequirementsByName = Dictionary(
            uniqueKeysWithValues: tools.compactMap { tool -> (String, Set<ToolRequirement>)? in
                let requirements = requirementsSatisfied(
                    by: tool.function,
                    availableRequirements: toolRequirements
                )

                return requirements.isEmpty
                    ? nil
                    : (tool.function.name, requirements)
            }
        )
        if !toolRequirements.isEmpty {
            let mappedToolNames = toolRequirementsByName.keys.sorted()

            print(
                "[tool loop] requirement-mapped tools: "
                    + mappedToolNames.joined(separator: ", ")
            )
            fflush(stdout)
        }

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
                            describing: toolCalls.map {
                                $0.function.name
                            }
                        )
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
                if conversationEndRequested {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                let includesEndConversation = toolCalls.contains {
                    $0.function.name == "end_conversation"
                }

                if includesEndConversation && toolCalls.count != 1 {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                for toolCall in toolCalls {
                    let result: String

                    if toolCall.function.name == "end_conversation" {
                        guard activeReminder == nil else {
                            throw AtlasError.toolRequiredButNotInvoked
                        }

                        guard toolCall.function.arguments.isEmpty else {
                            throw AtlasError.toolRequiredButNotInvoked
                        }

                        conversationEndRequested = true

                        result = """
                            {"ok":true,"message":"The conversation will end after your \
                            single short farewell is spoken."}
                            """
                    } else {
                        result = try await toolServer.runTool(toolCall)
                    }

                    let toolSucceeded =
                        (try? JSONDecoder().decode(
                            ToolSuccessResponse.self,
                            from: Data(result.utf8)
                        ))?.ok == true

                    if toolSucceeded,
                        let requirements = toolRequirementsByName[toolCall.function.name]
                    {
                        executedRequirements.formUnion(requirements)
                    }

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

            if mayRequireConversationEndTool && !conversationEndRequested {
                print(
                    "[tool loop] required end_conversation validation rejected"
                )
                print("[tool loop] reply: \(assistantMessage.content)")
                fflush(stdout)

                if retriedMissingConversationEndTool {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedMissingConversationEndTool = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                            Validation failure: the user clearly ended the conversation, but
                            you did not invoke end_conversation.

                            Do not write any user-facing prose yet. Your next response must
                            contain exactly one end_conversation tool call and no other tool
                            calls. After its successful tool result, reply with exactly one
                            brief farewell sentence.
                            """
                    )
                )

                continue
            }

            let missingRequirements = toolRequirements.subtracting(
                expandedRequirements(executedRequirements)
            )

            if !missingRequirements.isEmpty {
                print(
                    "[tool loop] required-tool validation rejected: "
                        + String(describing: missingRequirements)
                )
                print("[tool loop] reply: \(assistantMessage.content)")
                fflush(stdout)

                let alreadyRetried =
                    !retriedRequirements
                    .intersection(missingRequirements)
                    .isEmpty

                if alreadyRetried {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedRequirements.formUnion(missingRequirements)

                messages.append(
                    Message(
                        role: "user",
                        content: toolRequirementRetryInstruction(
                            for: missingRequirements
                        )
                    )
                )

                continue
            }

            let reply = assistantMessage.content
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            if conversationEndRequested && reply.isEmpty {
                throw AtlasError.toolRequiredButNotInvoked
            }

            if activeReminder != nil && !activeReminderAcknowledged
                && claimsReminderAcknowledgement(reply)
            {
                print(
                    "[tool loop] validation: reminder acknowledgement "
                        + "was claimed without acknowledge_notification"
                )
                print("[tool loop] rejected reply: \(reply)")
                fflush(stdout)

                if retriedReminderAcknowledgement {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedReminderAcknowledgement = true

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

            if conversationEndRequested {
                scheduleConversationEndAfterSpeech()

                try await onSentence(reply)
            } else {
                let accumulator = SentenceAccumulator()

                for sentence in accumulator.append(reply) {
                    try await onSentence(sentence)
                }

                if let remaining = accumulator.finish() {
                    try await onSentence(remaining)
                }
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

    private var endConversationTool: ToolDefinition {
        ToolDefinition(
            type: "function",
            function: ToolFunctionDefinition(
                name: "end_conversation",
                description: """
                    End the current voice conversation after speaking one short,
                    natural farewell. Use only when the user clearly indicates that
                    they are done, says goodbye, or says they need nothing else.
                    Do not use this if the user asks a question, makes a request,
                    may reasonably continue, or has an active reminder awaiting
                    acknowledgement.
                    """,
                parameters: ToolParameters(
                    type: "object",
                    required: [],
                    properties: [:]
                )
            )
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
            #"\bill\b"#,
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

    private func mayRequireConversationEndTool(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        guard !normalized.isEmpty else {
            return false
        }

        let endingPatterns = [
            #"\bbye(\s+bye)*$"#,
            #"\bgood\s*bye$"#,
            #"\bsee\s+(you|ya)$"#,
            #"\btalk\s+to\s+you\s+later$"#,
            #"\bcatch\s+you\s+later$"#,

            #"\bthats\s+all$"#,
            #"\bthat\s+is\s+all$"#,
            #"\bthats\s+it$"#,
            #"\bthat\s+is\s+it$"#,
            #"\bthats\s+everything$"#,
            #"\bthat\s+is\s+everything$"#,
            #"\ball\s+done$"#,
            #"\bnothing\s+else$"#,

            #"\bim\s+all\s+set$"#,
            #"\bi\s+am\s+all\s+set$"#,
            #"\bim\s+done$"#,
            #"\bi\s+am\s+done$"#,
            #"\bwere\s+done$"#,
            #"\bwe\s+are\s+done$"#,

            #"\bi\s+dont\s+need\s+(anything|help)(\s+else)?$"#,
            #"\bi\s+do\s+not\s+need\s+(anything|help)(\s+else)?$"#,

            #"\bno\s+thanks$"#,
            #"\bno\s+thank\s+you$"#,
            #"\bthanks$"#,
            #"\bthank\s+you$"#,
            #"\bthanks\s+you\s+too$"#,
            #"\bthank\s+you\s+you\s+too$"#,
            #"\bthanks\s+take\s+care$"#,
            #"\bthank\s+you\s+take\s+care$"#,

            #"\bplease\s+end\s+(the\s+)?conversation$"#,
            #"\bend\s+(the\s+|this\s+)?conversation$"#,
            #"\byou\s+can\s+end\s+(the\s+)?conversation$"#,
            #"\byou\s+can\s+stop\s+now$"#,
        ]

        return endingPatterns.contains { pattern in
            normalized.range(
                of: pattern,
                options: .regularExpression
            ) != nil
        }
    }

    private func mayRequireEventTool(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let eventWords = [
            "reminder",
            "reminders",
            "remind me",
            "remind",
            "reminding",

            "event",
            "events",
            "appointment",
            "appointments",
            "meeting",
            "meetings",

            "schedule",
            "schedules",
            "scheduled",
            "scheduling",

            "calendar",
            "calendars",
            "agenda",
            "itinerary",

            "notification",
            "notifications",
            "alert",
            "alerts",
            "alarm",
            "alarms",

            "due",
            "upcoming",
            "planned",
            "plan",
            "plans",
        ]

        return eventWords.contains { normalized.contains($0) }
    }

    private func mayRequireSchedulingTool(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let schedulingPhrases = [
            "wake me",
            "set an alarm",
            "set alarm",
            "alarm for",
            "in a minute",
            "in an hour",
            "every day",
            "every weekday",
            "every week",
        ]

        return schedulingPhrases.contains { phrase in
            normalized.contains(phrase)
        }
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

    private func toolRequirementRetryInstruction(
        for requirements: Set<ToolRequirement>
    ) -> String {
        let domains =
            requirements
            .map(toolRequirementDescription)
            .sorted()
            .joined(separator: ", ")

        return """
            Validation failure: the user's request requires a successful tool call \
            related to \(domains), but no applicable tool call was made.

            Do not provide a natural-language answer yet. Use the available tool or \
            tools that address the request, then answer only from their successful \
            results. If the available tools cannot perform the request, state that \
            limitation briefly.
            """
    }

    private func toolRequirementDescription(
        _ requirement: ToolRequirement
    ) -> String {
        switch requirement {
        case .light:
            return "lighting"
        case .event:
            return "events, reminders, or notifications"
        case .scheduling:
            return "scheduling or alarms"
        }
    }

    private func requirementsSatisfied(
        by tool: ToolFunctionDefinition,
        availableRequirements: Set<ToolRequirement>
    ) -> Set<ToolRequirement> {
        let text = normalizedText(
            "\(tool.name) \(tool.description)"
        )

        var result = Set<ToolRequirement>()

        if availableRequirements.contains(.light)
            && containsAny(
                in: text,
                phrases: [
                    "light",
                    "lights",
                    "lamp",
                    "lamps",
                    "lighting",
                ]
            )
        {
            result.insert(.light)
        }

        if availableRequirements.contains(.event)
            && containsAny(
                in: text,
                phrases: [
                    "reminder",
                    "event",
                    "calendar",
                    "notification",
                    "appointment",
                    "meeting",
                    "agenda",
                    "alert",
                ]
            )
        {
            result.insert(.event)
        }

        if availableRequirements.contains(.scheduling)
            && containsAny(
                in: text,
                phrases: [
                    "schedule",
                    "scheduled",
                    "scheduling",
                    "alarm",
                    "reminder",
                    "event",
                    "calendar",
                    "appointment",
                    "meeting",
                ]
            )
        {
            result.insert(.scheduling)
        }

        return result
    }

    private func containsAny(
        in text: String,
        phrases: [String]
    ) -> Bool {
        phrases.contains { text.contains($0) }
    }

    private func expandedRequirements(
        _ requirements: Set<ToolRequirement>
    ) -> Set<ToolRequirement> {
        var expanded = requirements

        if expanded.contains(.scheduling) {
            expanded.insert(.event)
        }

        return expanded
    }
}
