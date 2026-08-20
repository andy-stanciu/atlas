import Foundation

func makeCanonicalJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

final class LLMClient: @unchecked Sendable {
    enum ToolChoice: Encodable {
        case auto
        case function(name: String)

        private struct FunctionChoice: Encodable {
            struct Function: Encodable { let name: String }
            let type = "function"
            let function: Function
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .auto:
                var container = encoder.singleValueContainer()
                try container.encode("auto")
            case .function(let name):
                try FunctionChoice(function: .init(name: name)).encode(to: encoder)
            }
        }
    }

    private struct WireRequest: Encodable {
        struct WireMessage: Encodable {
            struct WireToolCall: Encodable {
                struct WireFunction: Encodable {
                    let name: String
                    let arguments: String
                }
                let id: String?
                let type = "function"
                let function: WireFunction
            }
            let role: String
            let content: String
            let tool_calls: [WireToolCall]?
            let tool_call_id: String?

            init(_ message: Message) {
                role = message.role
                content = message.content
                tool_call_id = message.toolCallID
                tool_calls = message.toolCalls?.map {
                    WireToolCall(
                        id: $0.id,
                        function: WireToolCall.WireFunction(
                            name: $0.function.name,
                            arguments: Self.stringify($0.function.arguments)
                        )
                    )
                }
            }

            private static func stringify(
                _ arguments: [String: JSONValue]
            ) -> String {
                guard let data = try? makeCanonicalJSONEncoder().encode(arguments) else {
                    return "{}"
                }
                return String(decoding: data, as: UTF8.self)
            }
        }

        let model: String
        let messages: [WireMessage]
        let tools: [ToolDefinition]?
        let tool_choice: ToolChoice?
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        let chat_template_kwargs: [String: Bool]
    }

    private struct WireStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct DeltaToolCall: Decodable {
                    struct DeltaFunction: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let id: String?
                    let index: Int?
                    let function: DeltaFunction?
                }
                let content: String?
                let tool_calls: [DeltaToolCall]?
            }
            let delta: Delta
        }
        let choices: [Choice]
    }

    // MARK: - Core chat API

    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double = Config.llmDefaultTemperature,
        toolChoice: ToolChoice? = nil,
        prefixTracked: Bool = true,
        onDelta: (String) -> Void
    ) async throws -> Message {
        var request = try makeRequest(
            messages: messages,
            tools: tools,
            temperature: temperature
        )
        request.httpBody = try makeCanonicalJSONEncoder().encode(
            WireRequest(
                model: Config.llmModel,
                messages: Self.normalizeMessages(messages)
                    .map(WireRequest.WireMessage.init),
                tools: tools.isEmpty ? nil : tools,
                tool_choice: toolChoice,
                temperature: temperature,
                max_tokens: Config.llmMaxTokens,
                stream: true,
                chat_template_kwargs: ["enable_thinking": false]
            )
        )

        if prefixTracked, let body = request.httpBody {
            LLMPrefixStability.check(body)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.system("LLM stream request failed. HTTP \(statusCode).")
            throw NSError(
                domain: "LLM",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "LLM stream request failed with HTTP \(statusCode)."
                ]
            )
        }

        let decoder = JSONDecoder()
        var content = ""
        var toolIDs: [Int: String] = [:]
        var toolNames: [Int: String] = [:]
        var toolArguments: [Int: String] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                let chunk = try? decoder.decode(
                    WireStreamChunk.self,
                    from: data
                ),
                let delta = chunk.choices.first?.delta
            else { continue }

            if let text = delta.content, !text.isEmpty {
                content += text
                onDelta(text)
            }
            for call in delta.tool_calls ?? [] {
                let index = call.index ?? 0
                if let id = call.id {
                    toolIDs[index] = id
                }
                if let name = call.function?.name {
                    toolNames[index, default: ""] += name
                }
                if let arguments = call.function?.arguments {
                    toolArguments[index, default: ""] += arguments
                }
            }
        }

        let toolCalls: [ToolCall]? =
            toolNames.isEmpty
            ? nil
            : toolNames
                .sorted { $0.key < $1.key }
                .map { index, name in
                    ToolCall(
                        id: toolIDs[index] ?? "call_\(index)",
                        type: "function",
                        function: ToolFunctionCall(
                            index: index,
                            name: name,
                            arguments: Self.parseArguments(
                                toolArguments[index] ?? "{}"
                            )
                        )
                    )
                }

        return Message(role: "assistant", content: content, toolCalls: toolCalls)
    }

    // MARK: - Auxiliary one-shot generators (prompts live in SystemPrompts)

    func generateScheduledSpeech(
        text: String,
        kind: SpeechKind,
        announcementNumber: Int,
        isConversationInterruption: Bool
    ) async throws -> String {
        let instruction: String

        switch kind {
        case .reminder:
            let reminderInstruction =
                announcementNumber > 1
                ? SystemPrompts.reminderRepeatInstruction
                    .replacingOccurrences(
                        of: "{ANNOUNCEMENT_NUMBER}",
                        with: String(announcementNumber)
                    )
                : SystemPrompts.reminderAnnouncementInstruction
            instruction = reminderInstruction

        case .announcement:
            instruction = SystemPrompts.announcementInstruction
        }

        let response = try await chatStream(
            messages: [
                Message(
                    role: "system",
                    content: SystemPrompts.mainSystemPrompt
                ),
                Message(
                    role: "system",
                    content: instruction
                ),
                Message(
                    role: "user",
                    content: "Speech text: \(text)"
                ),
            ],
            tools: [],
            prefixTracked: false,
            onDelta: { _ in }
        )

        let speech = response.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !speech.isEmpty else {
            return ""
        }

        if isConversationInterruption, kind == .reminder {
            return "By the way, \(speech)"
        }

        return speech
    }

    func extractSpeakerName(from utterance: String) async throws -> String? {
        let response = try await chatStream(
            messages: [
                Message(
                    role: "system",
                    content: SystemPrompts.speakerNameExtractionInstruction
                ),
                Message(role: "user", content: utterance),
            ],
            tools: [],
            // extraction should be temperature 0
            temperature: 0,
            prefixTracked: false,
            onDelta: { _ in }
        )

        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.uppercased() != "NO_NAME_PROVIDED", !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    // MARK: - Internals

    private static func normalizeMessages(
        _ messages: [Message]
    ) -> [Message] {
        let systemPrefixCount = messages.prefix {
            $0.role == "system"
        }.count

        guard systemPrefixCount > 1 else {
            return messages
        }

        let systemContent =
            messages
            .prefix(systemPrefixCount)
            .map(\.content)
            .joined(separator: "\n\n")

        return [
            Message(
                role: "system",
                content: systemContent
            )
        ] + messages.dropFirst(systemPrefixCount)
    }

    private func makeRequest(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double
    ) throws -> URLRequest {
        var request = URLRequest(
            url: Config.llmURL.appendingPathComponent("chat/completions")
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        return request
    }

    private static func parseArguments(_ raw: String) -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(
                [String: JSONValue].self,
                from: data
            )
        else {
            return [:]
        }
        return parsed
    }
}
