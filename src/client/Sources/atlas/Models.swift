import Foundation

struct Message: Codable, Sendable {
    let role: String
    let content: String
    let toolCalls: [ToolCall]?
    let toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

struct ToolCall: Codable, Sendable {
    let id: String?
    let type: String?
    let function: ToolFunctionCall

    init(
        id: String? = nil,
        type: String? = "function",
        function: ToolFunctionCall
    ) {
        self.id = id
        self.type = type
        self.function = function
    }
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
    let anonymous: Bool
}

struct SpeakerIdentificationResponse: Decodable, Sendable {
    let ok: Bool
    let status: SpeakerIdentificationStatus
    let profileID: Int?
    let displayName: String?
    let similarity: Double?
    let durationSeconds: Double?
    let anonymous: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case profileID = "profile_id"
        case displayName = "display_name"
        case similarity
        case durationSeconds = "duration_seconds"
        case anonymous
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
            similarity: similarity,
            anonymous: anonymous ?? false
        )
    }
}

struct SpeakerReinforceResponse: Decodable, Sendable {
    let ok: Bool
    let accepted: Bool
    let reason: String?
    let similarity: Double?
    let askIdentification: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case accepted
        case reason
        case similarity
        case askIdentification = "ask_identification"
    }
}
