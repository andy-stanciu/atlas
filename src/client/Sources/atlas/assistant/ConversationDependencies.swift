import Foundation

protocol LLMServing: Sendable {
    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        toolChoice: LLMClient.ToolChoice?,
        onDelta: (String) -> Void
    ) async throws -> Message
}

protocol ToolServing: Sendable {
    func availableTools() async throws -> [ToolDefinition]
    func runTool(_ call: ToolCall) async throws -> String
}

extension LLMClient: LLMServing {
    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        toolChoice: ToolChoice?,
        onDelta: (String) -> Void
    ) async throws -> Message {
        try await chatStream(
            messages: messages,
            tools: tools,
            temperature: Config.llmDefaultTemperature,
            toolChoice: toolChoice,
            onDelta: onDelta
        )
    }
}

extension ToolServerClient: ToolServing {}
