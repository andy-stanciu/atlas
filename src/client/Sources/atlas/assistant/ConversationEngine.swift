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
            return "LLM returned neither tool calls nor spoken text."

        case .toolLoopExceeded:
            return "Tool loop exceeded its maximum number of steps."

        case .toolRequiredButNotInvoked(let expected, let observed):
            return """
                Expected one of \(expected.sorted()) but observed \
                \(observed.sorted()).
                """

        case .reminderAcknowledgementNotInvoked:
            return """
                The tool loop exhausted its steps without an address_reminder \
                call while a reminder was active.
                """
        }
    }
}

private let reminderAddressTool = "address_reminder"

final class ConversationEngine: @unchecked Sendable {
    private let llm: any LLMServing
    private let toolServer: any ToolServing
    private let preloadedTools: [ToolDefinition]?
    private let maxSteps: Int
    private let systemPrompt: String
    private let normalize: (String) -> String
    private let onToolBatch: @Sendable ([ToolCall]) async -> Void
    private let onTextDelta: (String) -> Void

    init(
        llm: any LLMServing,
        toolServer: any ToolServing,
        preloadedTools: [ToolDefinition]? = nil,
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
        self.llm = llm
        self.toolServer = toolServer
        self.preloadedTools = preloadedTools
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
        speakerInstruction: String? = nil,
        trailingInstructions: [String] = []
    ) async throws -> ConversationResult {
        var messages = history
        var durableMessages = history
        var boundary: [String] = []
        if let speakerInstruction {
            boundary.append(speakerInstruction)
        }
        if let activeReminderText {
            boundary.append(SystemPrompts.activeReminderResponseInstruction)
            boundary.append(
                """
                Active reminder text:
                \(activeReminderText)
                """
            )
        }
        boundary.append(contentsOf: trailingInstructions)

        let userMessage = Message(role: "user", content: userText)
        messages.append(userMessage)
        durableMessages.append(userMessage)

        if !boundary.isEmpty {
            messages.append(
                Message(role: "user", content: boundary.joined(separator: "\n\n"))
            )
        }

        let tools: [ToolDefinition]
        if let preloadedTools {
            tools = preloadedTools
        } else {
            tools = try await toolServer.availableTools()
        }

        var attemptedToolNames: [String] = []
        var successfulToolNames: [String] = []
        var toolCalls: [ToolCall] = []
        var toolResults: [String] = []
        var reminderAddressed = activeReminderText == nil

        for step in 0..<maxSteps {
            try Task.checkCancellation()
            let passStart = CACurrentMediaTime()
            var firstTokenLogged = false
            let toolChoice: LLMClient.ToolChoice? =
                reminderAddressed ? nil : .function(name: reminderAddressTool)
            let assistantMessage = try await llm.chatStream(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
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

            let assistantHistoryMessage = Message(
                role: "assistant",
                content: assistantMessage.content,
                toolCalls: calls
            )
            messages.append(assistantHistoryMessage)
            durableMessages.append(assistantHistoryMessage)

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
                    }
                    if call.function.name == reminderAddressTool {
                        reminderAddressed = true
                    }
                    let toolHistoryMessage = Message(
                        role: "tool",
                        content: result
                    )
                    messages.append(toolHistoryMessage)
                    durableMessages.append(toolHistoryMessage)
                }

                continue
            }

            let reply = assistantMessage.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if reply.isEmpty {
                let retryMessage = Message(
                    role: "user",
                    content: """
                        You returned neither a tool call nor spoken text.
                        Return one short natural spoken response, or invoke the
                        required native tool now.
                        """
                )
                messages.append(retryMessage)
                durableMessages.append(retryMessage)
                continue
            }

            return ConversationResult(
                reply: reply,
                toolCalls: toolCalls,
                toolResults: toolResults,
                attemptedToolNames: attemptedToolNames,
                successfulToolNames: successfulToolNames,
                finalMessages: durableMessages
            )
        }

        if !reminderAddressed {
            throw ConversationEngineError.reminderAcknowledgementNotInvoked
        }

        throw ConversationEngineError.toolLoopExceeded
    }

    private func toolSucceeded(_ result: String) -> Bool {
        (try? JSONDecoder().decode(
            ToolSuccessResponse.self,
            from: Data(result.utf8)
        ))?.ok == true
    }
}
