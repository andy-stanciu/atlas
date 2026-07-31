import Foundation

final class ToolServerClient: @unchecked Sendable {
    func nextNotification() async throws -> PendingNotification? {
        let url = Config.toolServerURL
            .appendingPathComponent("notifications")
            .appendingPathComponent("next")

        var request = URLRequest(url: url)
        request.timeoutInterval = Config.toolServerTimeout

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            throw NSError(
                domain: "ToolServer",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not fetch pending notifications."
                ]
            )
        }

        let payload = try JSONDecoder().decode(
            PendingNotificationResponse.self,
            from: data
        )

        guard payload.ok else {
            throw NSError(
                domain: "ToolServer",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Tool server rejected notification request."
                ]
            )
        }

        return payload.notification
    }

    func markNotificationDelivered(
        notificationID: String
    ) async throws {
        let url = Config.toolServerURL
            .appendingPathComponent("notifications")
            .appendingPathComponent(notificationID)
            .appendingPathComponent("delivered")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.toolServerTimeout

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            let body = String(decoding: data, as: UTF8.self)

            throw NSError(
                domain: "ToolServer",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not mark notification delivered: \(body)"
                ]
            )
        }

        let payload = try JSONDecoder().decode(
            AcknowledgementResponse.self,
            from: data
        )

        guard payload.ok else {
            throw NSError(
                domain: "ToolServer",
                code: 13,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Tool server rejected notification delivery."
                ]
            )
        }
    }

    func availableTools() async throws -> [ToolDefinition] {
        let url = Config.toolServerURL
            .appendingPathComponent("tools")

        var request = URLRequest(url: url)
        request.timeoutInterval = Config.toolServerTimeout

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard
            let http = response as? HTTPURLResponse,
            200..<300 ~= http.statusCode
        else {
            throw NSError(
                domain: "ToolServer",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not load tool definitions from the tool server."
                ]
            )
        }

        return try JSONDecoder()
            .decode(ToolListResponse.self, from: data)
            .tools
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

        guard
            let http = response as? HTTPURLResponse,
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
