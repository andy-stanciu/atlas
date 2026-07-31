import Foundation

struct Message: Codable {
    let role: String
    let content: String
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }

    init(
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }
}

struct ToolCall: Codable {
    let type: String?
    let function: ToolFunctionCall
}

struct ToolFunctionCall: Codable {
    let index: Int?
    let name: String
    let arguments: [String: JSONValue]
}

struct ToolDefinition: Codable {
    let type: String
    let function: ToolFunctionDefinition
}

struct ToolFunctionDefinition: Codable {
    let name: String
    let description: String
    let parameters: ToolParameters
}

struct ToolParameters: Codable {
    let type: String
    let required: [String]
    let properties: [String: ToolProperty]

    enum CodingKeys: String, CodingKey {
        case type
        case required
        case properties
    }

    init(
        type: String,
        required: [String] = [],
        properties: [String: ToolProperty] = [:]
    ) {
        self.type = type
        self.required = required
        self.properties = properties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        type = try container.decode(String.self, forKey: .type)

        required =
            try container.decodeIfPresent(
                [String].self,
                forKey: .required
            ) ?? []

        properties =
            try container.decodeIfPresent(
                [String: ToolProperty].self,
                forKey: .properties
            ) ?? [:]
    }
}

struct ToolSuccessResponse: Decodable {
    let ok: Bool
}

struct ToolProperty: Codable {
    let type: String?
    let description: String?
    let enumValues: [String]?
    let items: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
    }
}

struct AcknowledgementResponse: Codable {
    let ok: Bool
    let notificationID: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case notificationID = "notification_id"
    }
}

struct ToolListResponse: Codable {
    let tools: [ToolDefinition]
}

struct ToolExecutionRequest: Codable {
    let name: String
    let arguments: [String: JSONValue]
}

struct OllamaRequest: Codable {
    let model: String
    let stream: Bool
    let think: Bool
    let messages: [Message]
    let options: Options
    let tools: [ToolDefinition]

    struct Options: Codable {
        let num_ctx: Int
        let temperature: Double
        let num_predict: Int
    }
}

struct OllamaStreamChunk: Codable {
    let message: Message?
    let done: Bool?
}

struct WhisperResponse: Codable {
    let text: String
}

enum AssistantState: Equatable {
    case listening
    case recording
    case processing
    case speaking
}

enum AtlasError: LocalizedError {
    case toolRequiredButNotInvoked
}
