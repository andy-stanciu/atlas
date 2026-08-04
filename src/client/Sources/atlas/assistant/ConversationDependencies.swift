import Foundation

protocol OllamaServing: Sendable {
    func chat(
        messages: [Message],
        tools: [ToolDefinition],
    ) async throws -> Message
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
}
extension ToolServerClient: ToolServing {}
