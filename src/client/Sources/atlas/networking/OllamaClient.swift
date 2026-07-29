import Foundation

final class OllamaClient: @unchecked Sendable {
    func chat(
        messages: [Message],
        tools: [ToolDefinition]
    ) async throws -> Message {
        let payload = OllamaRequest(
            model: Config.ollamaModel,
            stream: false,
            think: false,
            messages: messages,
            options: .init(
                num_ctx: 8192,
                temperature: 0.2,
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

        guard
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let statusCode =
                (response as? HTTPURLResponse)?
                .statusCode ?? -1

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

    func generateReminderSpeech(
        text: String,
        announcementNumber: Int,
        isConversationInterruption: Bool
    ) async throws -> String {
        let isRepeat = announcementNumber > 1

        let reminderInstruction =
            isRepeat
            ? SystemPrompts.reminderRepeatInstruction
                .replacingOccurrences(
                    of: "{ANNOUNCEMENT_NUMBER}",
                    with: String(announcementNumber)
                )
            : SystemPrompts.reminderAnnouncementInstruction

        let instruction: String

        if isConversationInterruption {
            instruction =
                SystemPrompts.reminderConversationInterruptionInstruction
                + "\n\n"
                + reminderInstruction
        } else {
            instruction = reminderInstruction
        }

        let response = try await chat(
            messages: [
                Message(
                    role: "system",
                    content: Config.systemPrompt
                ),
                Message(
                    role: "system",
                    content: instruction
                ),
                Message(
                    role: "user",
                    content: "Reminder text: \(text)"
                ),
            ],
            tools: []
        )

        let speech = response.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !speech.isEmpty else {
            return ""
        }

        if isConversationInterruption {
            return "By the way, \(speech)"
        }

        return speech
    }
}
