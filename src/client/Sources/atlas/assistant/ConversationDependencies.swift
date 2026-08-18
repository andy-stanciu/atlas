import Foundation

protocol OllamaServing: Sendable {
    func chat(
        messages: [Message],
        tools: [ToolDefinition],
    ) async throws -> Message

    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        onDelta: (String) -> Void
    ) async throws -> Message
}

extension OllamaServing {
    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        onDelta: (String) -> Void
    ) async throws -> Message {
        let message = try await chat(messages: messages, tools: tools)
        if !message.content.isEmpty {
            onDelta(message.content)
        }
        return message
    }
}

protocol ToolServing: Sendable {
    func availableTools() async throws -> [ToolDefinition]
    func runTool(_ call: ToolCall) async throws -> String
}

extension OllamaClient: OllamaServing {
    func chat(
        messages: [Message],
        tools: [ToolDefinition]
    ) async throws -> Message {
        try await chat(
            messages: messages,
            tools: tools,
            temperature: Config.ollamaDefaultTemperature
        )
    }

    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        onDelta: (String) -> Void
    ) async throws -> Message {
        try await chatStream(
            messages: messages,
            tools: tools,
            temperature: Config.ollamaDefaultTemperature,
            onDelta: onDelta
        )
    }
}
extension ToolServerClient: ToolServing {}
