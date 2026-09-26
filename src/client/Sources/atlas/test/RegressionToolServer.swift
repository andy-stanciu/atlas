import Foundation

actor RegressionToolServer: ToolServing {
    private let tools: [ToolDefinition]
    private var recordedCalls: [ToolCall] = []

    init(tools: [ToolDefinition]) {
        self.tools = tools
    }

    func availableTools() async throws -> [ToolDefinition] {
        tools
    }

    func runTool(_ call: ToolCall) async throws -> String {
        recordedCalls.append(call)
        return result(for: call)
    }

    func reset() {
        recordedCalls = []
    }

    func calls() -> [ToolCall] {
        recordedCalls
    }

    private func result(for call: ToolCall) -> String {
        switch call.function.name {
        case "get_current_datetime":
            return #"{"ok":true,"current_datetime":{"date":"2026-08-03","day_of_week":"Monday","time":"2:24 PM"}}"#

        case "set_light":
            let room = stringArgument("room", from: call) ?? "unknown"
            let power = stringArgument("power", from: call) ?? "unknown"
            return #"{"ok":true,"room":"\#(room)","power":"\#(power)"}"#

        case "get_light_status":
            let room = stringArgument("room", from: call) ?? "unknown"
            return #"{"ok":true,"room":"\#(room)","power":"on"}"#

        case "schedule_reminder":
            return #"{"ok":true,"id":101,"scheduled_for":"2026-08-03T02:25:00"}"#

        case "list_reminders":
            return #"{"ok":true,"reminders":[{"id":7,"text":"Call Mom","scheduled_for":"2026-08-03T05:00:00"}]}"#

        case "cancel_reminder":
            return #"{"ok":true,"cancelled":true}"#

        case "address_reminder":
            let acknowledged: Bool = {
                if case .bool(let value) = call.function.arguments["acknowledged"] {
                    return value
                }
                return false
            }()
            let status = acknowledged ? "acknowledged" : "still_active"
            return #"{"ok":true,"status":"\#(status)"}"#

        case "schedule_sequence":
            return #"{"ok":true,"id":201}"#

        case "list_sequences":
            return #"{"ok":true,"sequences":[]}"#

        case "cancel_sequence":
            return #"{"ok":true,"cancelled":true}"#

        case "music_play":
            let query = stringArgument("query", from: call) ?? "your music"
            return #"{"ok":true,"playing":"track","name":"\#(query)","artist":"Test Artist","started":true,"volume":50}"#

        case "music_pause":
            return #"{"ok":true,"status":"paused","name":"Test Song","artist":"Test Artist"}"#

        case "music_resume":
            return #"{"ok":true,"status":"playing","name":"Test Song","artist":"Test Artist","volume":50}"#

        case "music_skip":
            return #"{"ok":true,"status":"skipped","name":"Next Song","artist":"Test Artist","volume":50}"#

        case "music_previous":
            return #"{"ok":true,"status":"previous","name":"Prior Song","artist":"Test Artist","volume":50}"#

        case "music_volume":
            let percent = intArgument("percent", from: call) ?? 50
            return #"{"ok":true,"volume":\#(percent),"name":"Test Song","artist":"Test Artist"}"#

        case "music_status":
            return #"{"ok":true,"playing":true,"track":"Test Song","artist":"Test Artist","album":"Test Album","position_seconds":30,"duration_seconds":180,"volume":50}"#

        default:
            return #"{"ok":false,"error":"Unknown regression tool: \#(call.function.name)"}"#
        }
    }

    private func stringArgument(_ name: String, from call: ToolCall) -> String? {
        guard case .string(let value) = call.function.arguments[name] else {
            return nil
        }
        return value
    }

    private func intArgument(_ name: String, from call: ToolCall) -> Int? {
        guard case .number(let value) = call.function.arguments[name] else {
            return nil
        }
        return Int(value)
    }
}
