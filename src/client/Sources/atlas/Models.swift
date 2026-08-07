import Foundation

struct Message: Codable, Sendable {
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

struct ToolCall: Codable, Sendable {
    let type: String?
    let function: ToolFunctionCall
}

struct ToolFunctionCall: Codable, Sendable {
    let index: Int?
    let name: String
    let arguments: [String: JSONValue]
}

struct ToolDefinition: Codable, Sendable {
    let type: String
    let function: ToolFunctionDefinition
}

struct ToolFunctionDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: ToolParameters
}

struct ToolParameters: Codable, Sendable {
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

struct ToolProperty: Codable, Sendable {
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

struct ToolSuccessResponse: Decodable, Sendable {
    let ok: Bool
}

struct ToolListResponse: Codable, Sendable {
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

struct ActionEnvelope: Decodable {
    let decision: Decision
    let speech: String
    let calls: [ActionEnvelopeToolCall]

    enum Decision: String, Decodable {
        case respond
        case clarify
        case callTools = "call_tools"
    }
}

struct ActionEnvelopeToolCall: Decodable {
    let name: String
    let arguments: [String: JSONValue]
}

enum SpeakerIdentificationStatus: String, Codable, Sendable {
    case known
    case uncertain
    case unknown
}

struct SpeakerIdentity: Equatable, Sendable {
    let id: Int
    let displayName: String
    let similarity: Double
}

struct SpeakerIdentificationResponse: Decodable, Sendable {
    let ok: Bool
    let status: SpeakerIdentificationStatus
    let profileID: Int?
    let displayName: String?
    let similarity: Double?
    let durationSeconds: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case profileID = "profile_id"
        case displayName = "display_name"
        case similarity
        case durationSeconds = "duration_seconds"
        case error
    }

    var identity: SpeakerIdentity? {
        guard ok,
            status == .known,
            let profileID,
            let displayName,
            let similarity
        else {
            return nil
        }

        return SpeakerIdentity(
            id: profileID,
            displayName: displayName,
            similarity: similarity
        )
    }
}

struct SpeakerReinforceResponse: Decodable, Sendable {
    let ok: Bool
    let accepted: Bool
    let reason: String?
    let similarity: Double?
}
