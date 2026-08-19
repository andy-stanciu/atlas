import Foundation

final class LLMClient: @unchecked Sendable {
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
                guard let data = try? JSONEncoder().encode(arguments) else {
                    return "{}"
                }
                return String(decoding: data, as: UTF8.self)
            }
        }

        let model: String
        let messages: [WireMessage]
        let tools: [ToolDefinition]?
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        let chat_template_kwargs: [String: Bool]
    }

    private struct WireResponse: Decodable {
        struct Choice: Decodable {
            struct ResponseMessage: Decodable {
                struct ResponseToolCall: Decodable {
                    struct ResponseFunction: Decodable {
                        let name: String
                        let arguments: String
                    }
                    let id: String?
                    let function: ResponseFunction
                }
                let content: String?
                let tool_calls: [ResponseToolCall]?
            }
            let message: ResponseMessage
        }
        let choices: [Choice]
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

    func chat(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double = Config.llmDefaultTemperature
    ) async throws -> Message {
        let data = try await send(
            messages: messages,
            tools: tools,
            temperature: temperature
        )

        let response: WireResponse
        do {
            response = try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            Log.system(
                "LLM response decode failed: "
                    + String(decoding: data, as: UTF8.self)
            )
            throw error
        }

        guard let choice = response.choices.first else {
            throw NSError(
                domain: "LLM",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "LLM returned no choices."
                ]
            )
        }

        return Message(
            role: "assistant",
            content: choice.message.content ?? "",
            toolCalls: choice.message.tool_calls?.enumerated().map { index, call in
                ToolCall(
                    id: call.id ?? "call_\(index)",
                    type: "function",
                    function: ToolFunctionCall(
                        index: index,
                        name: call.function.name,
                        arguments: Self.parseArguments(call.function.arguments)
                    )
                )
            }
        )
    }

    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double = Config.llmDefaultTemperature,
        onDelta: (String) -> Void
    ) async throws -> Message {
        var request = try makeRequest(
            messages: messages,
            tools: tools,
            temperature: temperature
        )
        request.httpBody = try JSONEncoder().encode(
            WireRequest(
                model: Config.llmModel,
                messages: Self.normalizeMessages(messages)
                    .map(WireRequest.WireMessage.init),
                tools: tools.isEmpty ? nil : tools,
                temperature: temperature,
                max_tokens: Config.llmMaxTokens,
                stream: true,
                chat_template_kwargs: ["enable_thinking": false]
            )
        )

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

        let response = try await chat(
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

    func generateFarewell(
        speakerInstruction: String? = nil
    ) async throws -> String {
        var messages = [
            Message(
                role: "system",
                content: SystemPrompts.mainSystemPrompt
            ),
            Message(
                role: "system",
                content: SystemPrompts.farewellInstruction
            ),
        ]

        if let speakerInstruction {
            messages.append(
                Message(
                    role: "system",
                    content: speakerInstruction
                )
            )
        }

        messages.append(
            Message(role: "user", content: "Goodbye, Atlas.")
        )

        let response = try await chat(
            messages: messages,
            tools: [],
            temperature: Config.llmConversationalTemperature
        )

        return response.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    func generateSpeakerNameRequest() async throws -> String {
        let response = try await chat(
            messages: [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt),
                Message(
                    role: "system",
                    content: SystemPrompts.speakerNameRequestInstruction
                ),
                Message(
                    role: "user",
                    content: "You don't recognize this speaker's voice."
                ),
            ],
            tools: [],
            temperature: Config.llmConversationalTemperature
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func extractSpeakerName(from utterance: String) async throws -> String? {
        let response = try await chat(
            messages: [
                Message(
                    role: "system",
                    content: SystemPrompts.speakerNameExtractionInstruction
                ),
                Message(role: "user", content: utterance),
            ],
            tools: [],
            // extraction should be temperature 0
            temperature: 0
        )

        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.uppercased() != "NO_NAME_PROVIDED", !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    func generateEnrollmentAcknowledgement(name: String) async throws -> String {
        let response = try await chat(
            messages: [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt),
                Message(
                    role: "system",
                    content: SystemPrompts.speakerEnrollmentAcknowledgementInstruction
                ),
                Message(role: "user", content: "My name is \(name)."),
            ],
            tools: [],
            temperature: Config.llmConversationalTemperature
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateEnrollmentDeclineAcknowledgement() async throws -> String {
        let response = try await chat(
            messages: [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt),
                Message(
                    role: "system",
                    content: SystemPrompts.speakerEnrollmentDeclineInstruction
                ),
                Message(role: "user", content: "I'd rather not share my name."),
            ],
            tools: [],
            temperature: Config.llmConversationalTemperature
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func send(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double
    ) async throws -> Data {
        var request = try makeRequest(
            messages: messages,
            tools: tools,
            temperature: temperature
        )
        request.httpBody = try JSONEncoder().encode(
            WireRequest(
                model: Config.llmModel,
                messages: Self.normalizeMessages(messages)
                    .map(WireRequest.WireMessage.init),
                tools: tools.isEmpty ? nil : tools,
                temperature: temperature,
                max_tokens: Config.llmMaxTokens,
                stream: false,
                chat_template_kwargs: ["enable_thinking": false]
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.system(
                "LLM request failed. "
                    + "HTTP \(statusCode). Response: "
                    + String(decoding: data, as: UTF8.self)
            )
            throw NSError(
                domain: "LLM",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "LLM request failed with HTTP \(statusCode)."
                ]
            )
        }
        return data
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
