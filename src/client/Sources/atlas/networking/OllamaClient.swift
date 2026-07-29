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
                num_ctx: 4096,
                temperature: 0.1,
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
        announcementNumber: Int
    ) async throws -> String {
        let isRepeat = announcementNumber > 1
        let instruction =
            isRepeat
            ? SystemPrompts.reminderRepeatInstruction
                .replacingOccurrences(
                    of: "{ANNOUNCEMENT_NUMBER}",
                    with: String(announcementNumber)
                )
            : SystemPrompts.reminderAnnouncementInstruction

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

        return response.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}
