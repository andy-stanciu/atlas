import Foundation

final class ToolServerClient: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedTools: [ToolDefinition]?

    func nextSpeech() async throws -> PendingSpeech? {
        let url = Config.toolServerURL
            .appendingPathComponent("speech")
            .appendingPathComponent("next")

        var request = URLRequest(url: url)
        request.timeoutInterval = Config.toolServerTimeout

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            throw NSError(
                domain: "ToolServer",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not fetch pending speech."
                ]
            )
        }

        let payload = try JSONDecoder().decode(
            PendingSpeechResponse.self,
            from: data
        )

        guard payload.ok else {
            throw NSError(
                domain: "ToolServer",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Tool server rejected the speech request."
                ]
            )
        }

        return payload.speech
    }

    func markAnnouncementDelivered(
        speechID: Int
    ) async throws {
        let url = Config.toolServerURL
            .appendingPathComponent("speech")
            .appendingPathComponent("announcement")
            .appendingPathComponent(String(speechID))
            .appendingPathComponent("delivered")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.toolServerTimeout

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let body = String(decoding: data, as: UTF8.self)

            throw NSError(
                domain: "ToolServer",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not mark announcement delivered: \(body)"
                ]
            )
        }

        let payload = try JSONDecoder().decode(
            ToolSuccessResponse.self,
            from: data
        )

        guard payload.ok else {
            throw NSError(
                domain: "ToolServer",
                code: 13,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Tool server rejected announcement delivery."
                ]
            )
        }
    }

    func availableTools() async throws -> [ToolDefinition] {
        if let tools = lock.withLock({ cachedTools }) {
            return tools
        }

        let url = Config.toolServerURL
            .appendingPathComponent("tools")

        var request = URLRequest(url: url)
        request.timeoutInterval = Config.toolServerTimeout

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            throw NSError(
                domain: "ToolServer",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not load tool definitions."
                ]
            )
        }

        let tools = try JSONDecoder()
            .decode(ToolListResponse.self, from: data)
            .tools

        lock.withLock {
            cachedTools = tools
        }

        return tools
    }

    func runTool(_ call: ToolCall) async throws -> String {
        let url = Config.toolServerURL
            .appendingPathComponent("tools")
            .appendingPathComponent("call")

        let payload = ToolExecutionRequest(
            name: call.function.name,
            arguments: call.function.arguments
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.toolServerTimeout

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
            let body = String(decoding: data, as: UTF8.self)

            throw NSError(
                domain: "ToolServer",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Tool server call failed: \(body)"
                ]
            )
        }

        _ = try JSONSerialization.jsonObject(with: data)
        return String(decoding: data, as: UTF8.self)
    }
}
