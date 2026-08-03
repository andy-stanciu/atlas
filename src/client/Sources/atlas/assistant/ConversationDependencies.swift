import Foundation

protocol OllamaServing: Sendable {
    func chat(
        messages: [Message],
        tools: [ToolDefinition]
    ) async throws -> Message
}

protocol ToolServing: Sendable {
    func availableTools() async throws -> [ToolDefinition]
    func runTool(_ call: ToolCall) async throws -> String
}

extension OllamaClient: OllamaServing {}
extension ToolServerClient: ToolServing {}
