import Foundation

enum PersistentLog {
    struct TurnHandle {
        let conversationURL: URL
        let turnID: Int
    }

    private static let lock = NSLock()

    private static let sessionURL: URL? = {
        guard Config.persistentLogMode else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let url = URL(fileURLWithPath: Config.logRootPath)
            .appendingPathComponent("session-\(formatter.string(from: Date()))")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            Log.system(
                "[persistent log] could not create session folder: \(error.localizedDescription)")
            return nil
        }
    }()

    private static var nextConversationID = 1
    private static var currentConversationURL: URL?
    private static var nextTurnID = 1

    static func beginConversation() {
        guard let sessionURL else { return }
        lock.withLock {
            let id = nextConversationID
            nextConversationID += 1
            nextTurnID = 1
            let url = sessionURL.appendingPathComponent("conversation-\(id)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            currentConversationURL = url
        }
    }

    static func beginTurn() -> TurnHandle? {
        lock.withLock {
            guard let currentConversationURL else { return nil }
            let id = nextTurnID
            nextTurnID += 1
            return TurnHandle(conversationURL: currentConversationURL, turnID: id)
        }
    }

    static func saveSpeech(_ handle: TurnHandle, wavURL: URL, transcript: String) {
        let destWAV = handle.conversationURL
            .appendingPathComponent("turn-\(handle.turnID)-speech.wav")
        try? FileManager.default.copyItem(at: wavURL, to: destWAV)

        let destText = handle.conversationURL
            .appendingPathComponent("turn-\(handle.turnID)-speech.txt")
        try? transcript.write(to: destText, atomically: true, encoding: .utf8)
    }

    static func saveResponse(
        _ handle: TurnHandle,
        toolCalls: [ToolCall],
        toolResults: [String],
        reply: String
    ) {
        var lines: [String] = []
        for (call, result) in zip(toolCalls, toolResults) {
            lines.append("[tool call] \(call.function.name)(\(encodedArguments(call)))")
            lines.append("[tool result] \(result)")
        }
        if !lines.isEmpty {
            lines.append("")
        }
        lines.append(reply)

        let dest = handle.conversationURL
            .appendingPathComponent("turn-\(handle.turnID)-response.txt")
        try? lines.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
    }

    private static func encodedArguments(_ call: ToolCall) -> String {
        guard let data = try? JSONEncoder().encode(call.function.arguments),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
