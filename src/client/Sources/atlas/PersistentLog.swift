import Foundation

enum PersistentLog {
    struct TurnHandle {
        let conversationURL: URL
        let turnID: Int
    }

    private static let lock = NSLock()

    private static let session: (url: URL, transcriptHandle: FileHandle?)? = {
        guard Config.persistentLogMode else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let url = URL(fileURLWithPath: Config.logRootPath)
            .appendingPathComponent("session-\(formatter.string(from: Date()))")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.system(
                "[persistent log] could not create session folder: \(error.localizedDescription)")
            return nil
        }

        let transcriptURL = url.appendingPathComponent("full-transcript.txt")
        var handle: FileHandle?
        if FileManager.default.createFile(atPath: transcriptURL.path, contents: nil) {
            handle = try? FileHandle(forWritingTo: transcriptURL)
        }
        return (url, handle)
    }()

    private static var sessionURL: URL? { session?.url }

    private static var nextConversationID = 1
    private static var currentConversationURL: URL?
    private static var nextTurnID = 1
    private static var nextUnattachedTurnID = 1
    private static var conversationTranscriptHandle: FileHandle?

    private static var unattachedURL: URL? {
        guard let url = sessionURL?.appendingPathComponent("unattached") else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func beginConversation() {
        guard let sessionURL else { return }
        lock.withLock {
            let id = nextConversationID
            nextConversationID += 1
            nextTurnID = 1
            let url = sessionURL.appendingPathComponent("conversation-\(id)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            currentConversationURL = url

            conversationTranscriptHandle?.closeFile()
            conversationTranscriptHandle = nil
            let transcriptURL = url.appendingPathComponent("conversation-transcript.txt")
            if FileManager.default.createFile(atPath: transcriptURL.path, contents: nil) {
                conversationTranscriptHandle = try? FileHandle(forWritingTo: transcriptURL)
            }
        }
    }

    static func endConversation() {
        lock.withLock {
            conversationTranscriptHandle?.closeFile()
            conversationTranscriptHandle = nil
            currentConversationURL = nil
        }
    }

    static func appendTranscript(_ text: String) {
        lock.withLock {
            let data = Data(text.utf8)
            session?.transcriptHandle?.write(data)
            conversationTranscriptHandle?.write(data)
        }
    }

    static func beginTurn() -> TurnHandle? {
        lock.withLock {
            if let currentConversationURL {
                let id = nextTurnID
                nextTurnID += 1
                return TurnHandle(conversationURL: currentConversationURL, turnID: id)
            }
            guard let unattachedURL else { return nil }
            let id = nextUnattachedTurnID
            nextUnattachedTurnID += 1
            return TurnHandle(conversationURL: unattachedURL, turnID: id)
        }
    }

    static func saveSpeech(_ handle: TurnHandle, input: STTInput, transcript: String) {
        if !input.pcm.isEmpty {
            try? writeWAV(
                pcm: input.pcm, sampleRate: input.sampleRate, to: path(handle, "speech.wav"))
        }
        try? transcript.write(to: path(handle, "speech.txt"), atomically: true, encoding: .utf8)
    }

    static func saveDiscarded(_ input: STTInput, transcript: String, reason: String) {
        guard let handle = beginTurn() else { return }
        saveSpeech(handle, input: input, transcript: transcript)
        try? "[\(reason)]".write(
            to: path(handle, "response.txt"), atomically: true, encoding: .utf8)
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

        try? lines.joined(separator: "\n").write(
            to: path(handle, "response.txt"), atomically: true, encoding: .utf8)
    }

    private static func path(_ handle: TurnHandle, _ name: String) -> URL {
        handle.conversationURL.appendingPathComponent("turn-\(handle.turnID)-\(name)")
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
