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
                num_ctx: 8192,
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

            print(
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
            print(
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

            instruction =
                isConversationInterruption
                ? SystemPrompts.reminderConversationInterruptionInstruction
                    + "\n\n"
                    + reminderInstruction
                : reminderInstruction

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
            temperature: 0.5
        )

        return response.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}
