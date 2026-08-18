import Foundation
import QuartzCore

struct ConversationResult: Sendable {
    let reply: String
    let toolCalls: [ToolCall]
    let toolResults: [String]
    let attemptedToolNames: [String]
    let successfulToolNames: [String]
    let finalMessages: [Message]
}

enum ConversationEngineError: LocalizedError, Equatable {
    case emptyResponse
    case toolLoopExceeded
    case toolRequiredButNotInvoked(
        expected: Set<String>,
        observed: Set<String>
    )
    case reminderAcknowledgementNotInvoked

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Ollama returned neither tool calls nor spoken text."

        case .toolLoopExceeded:
            return "Tool loop exceeded its maximum number of steps."

        case .toolRequiredButNotInvoked(let expected, let observed):
            return """
                Expected one of \(expected.sorted()) but observed \
                \(observed.sorted()).
                """

        case .reminderAcknowledgementNotInvoked:
            return """
                The model claimed an active reminder was acknowledged without a \
                successful acknowledge_reminder call.
                """
        }
    }
}

final class ConversationEngine: @unchecked Sendable {
    private let ollama: any OllamaServing
    private let toolServer: any ToolServing
    private let maxSteps: Int
    private let systemPrompt: String
    private let normalize: (String) -> String
    private let onToolBatch: @Sendable ([ToolCall]) async -> Void
    private let onTextDelta: (String) -> Void

    init(
        ollama: any OllamaServing,
        toolServer: any ToolServing,
        maxSteps: Int = Config.maxToolLoopSteps,
        systemPrompt: String = SystemPrompts.mainSystemPrompt,
        normalize: @escaping (String) -> String = {
            $0.lowercased()
                .replacingOccurrences(
                    of: "'",
                    with: ""
                )
                .replacingOccurrences(
                    of: "’",
                    with: ""
                )
                .replacingOccurrences(
                    of: #"[^a-z\s]"#,
                    with: " ",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        },
        onToolBatch: @escaping @Sendable ([ToolCall]) async -> Void = { _ in },
        onTextDelta: @escaping (String) -> Void = { _ in }
    ) {
        self.ollama = ollama
        self.toolServer = toolServer
        self.maxSteps = maxSteps
        self.systemPrompt = systemPrompt
        self.normalize = normalize
        self.onToolBatch = onToolBatch
        self.onTextDelta = onTextDelta
    }

    func respond(
        to userText: String,
        history: [Message] = [
            Message(role: "system", content: SystemPrompts.mainSystemPrompt)
        ],
        activeReminderText: String? = nil,
        speakerInstruction: String? = nil
    ) async throws -> ConversationResult {
        var messages = history

        if let speakerInstruction {
            messages.append(
                Message(
                    role: "system",
                    content: speakerInstruction
                )
            )
        }

        if let activeReminderText {
            messages.append(
                Message(
                    role: "system",
                    content: SystemPrompts.activeReminderResponseInstruction
                )
            )

            messages.append(
                Message(
                    role: "system",
                    content: """
                        Active reminder text:
                        \(activeReminderText)
                        """
                )
            )
        }

        messages.append(
            Message(role: "user", content: userText)
        )

        let tools = try await toolServer.availableTools()

        var attemptedToolNames: [String] = []
        var successfulToolNames: [String] = []
        var toolCalls: [ToolCall] = []
        var toolResults: [String] = []
        var activeReminderAcknowledged = false
        var retriedReminderAcknowledgement = false

        for step in 0..<maxSteps {
            try Task.checkCancellation()
            let passStart = CACurrentMediaTime()
            var firstTokenLogged = false
            let assistantMessage = try await ollama.chatStream(
                messages: messages,
                tools: tools,
                onDelta: { delta in
                    if !firstTokenLogged {
                        firstTokenLogged = true
                        Log.timing(
                            "LLM prefill: "
                                + String(
                                    format: "%.3f",
                                    CACurrentMediaTime() - passStart
                                ) + "s"
                        )
                    }
                    onTextDelta(delta)
                }
            )

            let calls = assistantMessage.toolCalls ?? []

            messages.append(
                Message(
                    role: "assistant",
                    content: assistantMessage.content,
                    toolCalls: calls
                )
            )

            if !calls.isEmpty {
                Log.toolLoop("step \(step + 1)")
                Log.toolLoop(
                    "tool calls: "
                        + String(
                            describing: calls.map(\.function.name)
                        )
                )
                await onToolBatch(calls)
                for call in calls {
                    try Task.checkCancellation()
                    attemptedToolNames.append(call.function.name)
                    toolCalls.append(call)

                    let result = try await toolServer.runTool(call)
                    try Task.checkCancellation()
                    toolResults.append(result)
                    Log.toolResult(call.function.name, result)
                    if toolSucceeded(result) {
                        successfulToolNames.append(call.function.name)

                        if call.function.name == "acknowledge_reminder" {
                            activeReminderAcknowledged = true
                        }
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
                messages.append(
                    Message(
                        role: "user",
                        content: """
                            You returned neither a tool call nor spoken text.
                            Return one short natural spoken response, or invoke the
                            required native tool now.
                            """
                    )
                )
                continue
            }

            if activeReminderText != nil,
                !activeReminderAcknowledged,
                claimsReminderAcknowledgement(reply)
            {
                if retriedReminderAcknowledgement {
                    throw ConversationEngineError
                        .reminderAcknowledgementNotInvoked
                }

                retriedReminderAcknowledgement = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                            Validation failure: you claimed the active reminder was
                            completed, dismissed, or acknowledged without a successful
                            acknowledge_reminder tool call.

                            Invoke acknowledge_reminder now if the user completed or
                            dismissed it. Otherwise speak naturally without claiming
                            completion.
                            """
                    )
                )
                continue
            }

            return ConversationResult(
                reply: reply,
                toolCalls: toolCalls,
                toolResults: toolResults,
                attemptedToolNames: attemptedToolNames,
                successfulToolNames: successfulToolNames,
                finalMessages: messages
            )
        }

        throw ConversationEngineError.toolLoopExceeded
    }

    private func toolSucceeded(_ result: String) -> Bool {
        (try? JSONDecoder().decode(
            ToolSuccessResponse.self,
            from: Data(result.utf8)
        ))?.ok == true
    }

    private func claimsReminderAcknowledgement(
        _ text: String
    ) -> Bool {
        let normalized = normalize(text)

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
