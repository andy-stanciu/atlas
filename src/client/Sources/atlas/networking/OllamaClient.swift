import Foundation

final class OllamaClient: @unchecked Sendable {
    func chat(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double = Config.ollamaDefaultTemperature,
    ) async throws -> Message {
        let payload = OllamaRequest(
            model: Config.ollamaModel,
            stream: false,
            think: false,
            messages: messages,
            options: .init(
                num_ctx: Config.ollamaContextWindow,
                temperature: temperature,
                num_predict: 400
            ),
            tools: tools
        )

        var request = URLRequest(url: Config.ollamaURL)
        request.httpMethod = "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            let body = String(decoding: data, as: UTF8.self)

            Log.system(
                "Ollama request failed. "
                    + "HTTP \(statusCode). Response: \(body)"
            )

            throw NSError(
                domain: "Ollama",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Ollama request failed with HTTP \(statusCode)."
                ]
            )
        }

        let chunk: OllamaStreamChunk

        do {
            chunk = try JSONDecoder().decode(
                OllamaStreamChunk.self,
                from: data
            )
        } catch {
            Log.system(
                "Ollama response decode failed: "
                    + String(decoding: data, as: UTF8.self)
            )
            throw error
        }

        guard let message = chunk.message else {
            throw NSError(
                domain: "Ollama",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Ollama returned no message."
                ]
            )
        }

        return message
    }

    func chatStream(
        messages: [Message],
        tools: [ToolDefinition],
        temperature: Double = Config.ollamaDefaultTemperature,
        onDelta: (String) -> Void
    ) async throws -> Message {
        let payload = OllamaRequest(
            model: Config.ollamaModel,
            stream: true,
            think: false,
            messages: messages,
            options: .init(
                num_ctx: Config.ollamaContextWindow,
                temperature: temperature,
                num_predict: 400
            ),
            tools: tools
        )

        var request = URLRequest(url: Config.ollamaURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.system("Ollama stream request failed. HTTP \(statusCode).")
            throw NSError(
                domain: "Ollama",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Ollama stream request failed with HTTP \(statusCode)."
                ]
            )
        }

        let decoder = JSONDecoder()
        var content = ""
        var toolCalls: [ToolCall]?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
            }
            guard
                let chunk = try? decoder.decode(
                    OllamaStreamChunk.self,
                    from: data
                )
            else {
                continue
            }
            if let delta = chunk.message?.content, !delta.isEmpty {
                content += delta
                onDelta(delta)
            }
            if let calls = chunk.message?.toolCalls, !calls.isEmpty {
                toolCalls = calls
            }
            if chunk.done == true {
                break
            }
        }

        return Message(role: "assistant", content: content, toolCalls: toolCalls)
    }

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

        // Use a higher temperature for farewells to encourage more variety and naturalness.
        let response = try await chat(
            messages: messages,
            tools: [],
            temperature: Config.ollamaConversationalTemperature
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
            temperature: Config.ollamaConversationalTemperature
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
            temperature: Config.ollamaConversationalTemperature
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
            temperature: Config.ollamaConversationalTemperature
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
