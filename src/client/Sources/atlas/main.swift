import AVFoundation
import Foundation
import QuartzCore


struct Config {
    static let whisperURL = URL(
        string: "http://127.0.0.1:8081/v1/audio/transcriptions"
    )!

    static let ollamaURL = URL(
        string: "http://127.0.0.1:11434/api/chat"
    )!

    static let toolServerURL = URL(
        string: "http://127.0.0.1:8090"
    )!

    static let toolServerTimeout: TimeInterval = 5

    static let ollamaModel = "qwen3.5:9b"

    static let maxToolLoopSteps = 10

    static let pythonExecutable =
        ProcessInfo.processInfo.environment["PYTHON_EXECUTABLE"]
        ?? "\(NSHomeDirectory())/workplace/atlas/src/client/.venv/bin/python"

    static let ttsWorkerScript =
        "\(NSHomeDirectory())/workplace/atlas/src/client/kokoro_worker.py"

    static let speechThreshold: Float = 0.025
    static let speechPeakThreshold: Float = 0.055

    static let startSpeechFrames = 2
    static let interruptSpeechFrames = 4
    static let endSilenceFrames = 15
    static let minimumRecordingBytes = 2_000
    static let preRollMilliseconds = 500

    static let conversationTimeoutSeconds: TimeInterval = 10

    static let wakeGreetings = [
        "hey",
        "hi",
        "hello",
        "good morning",
        "good afternoon",
        "good evening"
    ]

    static let maxHistoryMessages = 10

    static let systemPrompt = """
    # Overview
    Your name is Atlas. You are a concise, helpful voice assistant that has control over a house via a set of tools. 
    Without invoking tool calls, you have zero control or knowledge about the house. 
    Your responses are being spoken aloud to the user in real time.
    Always reply in natural spoken English. Answer routine questions directly.
    Never use code blocks or math equations, even if the user requests them.
    Never use special characters or unusual punctuation. Favor words instead.
    Use at most two short sentences unless the user explicitly requests detail.

    # Tool Use (Important!)
    ### Date and time
    - Use get_current_datetime whenever the user asks for the current time, date,
    day of week, month, year, or local time.
    - Never state the current date or time from memory; only report it after a
    successful get_current_datetime result.

    ### Lights
    - For any question or request about lights, including their current state,
    whether they are on or off, or changing their state, you must invoke the
    appropriate light tool before giving any user-facing answer.
    - Do not say that you will check, have checked, changed, turned on, turned off,
    or know the state of any light unless this conversation contains a successful
    tool result for that exact operation.
    - For requests about all rooms, invoke the required tool once for each room.
    - After tool results arrive, give one concise answer based only on those results.
    - If the user's room is ambiguous, ask which room they mean instead of invoking
    a tool.
    """
}


struct Message: Codable {
    let role: String
    let content: String
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }

    init(
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }
}


struct ToolCall: Codable {
    let type: String?
    let function: ToolFunctionCall
}


struct ToolFunctionCall: Codable {
    let index: Int?
    let name: String
    let arguments: [String: String]
}


struct ToolDefinition: Codable {
    let type: String
    let function: ToolFunctionDefinition
}


struct ToolFunctionDefinition: Codable {
    let name: String
    let description: String
    let parameters: ToolParameters
}


struct ToolParameters: Codable {
    let type: String
    let required: [String]
    let properties: [String: ToolProperty]
}


struct ToolProperty: Codable {
    let type: String
    let description: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
    }
}

struct ToolListResponse: Codable {
    let tools: [ToolDefinition]
}


struct ToolExecutionRequest: Codable {
    let name: String
    let arguments: [String: String]
}


struct OllamaRequest: Codable {
    let model: String
    let stream: Bool
    let think: Bool
    let messages: [Message]
    let options: Options
    let tools: [ToolDefinition]

    struct Options: Codable {
        let num_ctx: Int
        let temperature: Double
        let num_predict: Int
    }
}


struct OllamaStreamChunk: Codable {
    let message: Message?
    let done: Bool?
}


struct WhisperResponse: Codable {
    let text: String
}


enum AssistantState: Equatable {
    case listening
    case recording
    case processing
    case speaking
}


enum AtlasError: LocalizedError {
    case toolRequiredButNotInvoked
}


final class SentenceAccumulator {
    private var pending = ""

    func append(_ text: String) -> [String] {
        pending += text
        var sentences = [String]()

        while let boundary = findSentenceBoundary(in: pending) {
            let sentence = String(pending[..<boundary.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            pending = String(pending[boundary.upperBound...])

            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        // Do not wait forever if the LLM produces an unusually long
        // response with no sentence-ending punctuation.
        if pending.count >= 300 {
            let splitIndex = bestSplitIndex(in: pending, near: 270)

            let chunk = String(pending[..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            pending = String(pending[splitIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunk.isEmpty {
                sentences.append(chunk)
            }
        }

        return sentences
    }

    func finish() -> String? {
        let final = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return final.isEmpty ? nil : final
    }

    private func findSentenceBoundary(
        in text: String
    ) -> Range<String.Index>? {
        for index in text.indices {
            let character = text[index]

            guard character == "." || character == "!" || character == "?"
            else {
                continue
            }

            let next = text.index(after: index)

            if next == text.endIndex || text[next].isWhitespace {
                return index..<next
            }
        }

        return nil
    }

    private func bestSplitIndex(
        in text: String,
        near offset: Int
    ) -> String.Index {
        let target = text.index(
            text.startIndex,
            offsetBy: min(offset, text.count)
        )

        var index = target

        while index > text.startIndex {
            if text[index].isWhitespace {
                return index
            }

            index = text.index(before: index)
        }

        return target
    }
}


final class KokoroWorker {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()

    init() throws {
        process.executableURL = URL(fileURLWithPath: Config.pythonExecutable)
        process.arguments = [Config.ttsWorkerScript]
        process.standardInput = stdin
        process.standardOutput = stdout

        // Let Python/Torch/Hugging Face warnings go to the terminal.
        // Do not put stderr into an unread Pipe, which can deadlock.
        process.standardError = FileHandle.standardError

        try process.run()

        var startupLines = [String]()

        while true {
            let line = try readLine()

            if line == "READY" {
                break
            }

            startupLines.append(line)

            if startupLines.count >= 20 {
                throw NSError(
                    domain: "Kokoro",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Kokoro worker did not become ready. Output:\n"
                            + startupLines.joined(separator: "\n")
                    ]
                )
            }
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    func synthesize(text: String) throws -> URL {
        try lock.withLock {
            guard process.isRunning else {
                throw NSError(
                    domain: "Kokoro",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Kokoro worker is not running."
                    ]
                )
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-tts-\(UUID().uuidString).wav")

            let request: [String: String] = [
                "text": text,
                "output_path": outputURL.path,
            ]

            let requestData = try JSONSerialization.data(
                withJSONObject: request,
                options: []
            )

            stdin.fileHandleForWriting.write(requestData)
            stdin.fileHandleForWriting.write(Data([0x0A]))

            let responseLine = try readLine()
            let responseData = Data(responseLine.utf8)

            guard
                let response = try JSONSerialization.jsonObject(
                    with: responseData
                ) as? [String: Any],
                response["ok"] as? Bool == true,
                FileManager.default.fileExists(atPath: outputURL.path)
            else {
                let errorMessage = (
                    try? JSONSerialization.jsonObject(with: responseData)
                        as? [String: Any]
                )?["error"] as? String ?? responseLine

                throw NSError(
                    domain: "Kokoro",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Kokoro generation failed: \(errorMessage)"
                    ]
                )
            }

            return outputURL
        }
    }

    private func readLine() throws -> String {
        var bytes = [UInt8]()

        while true {
            let data = try stdout.fileHandleForReading.read(upToCount: 1)

            guard let data, let byte = data.first else {
                throw NSError(
                    domain: "Kokoro",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Kokoro worker closed its output stream."
                    ]
                )
            }

            if byte == 0x0A {
                break
            }

            bytes.append(byte)
        }

        return String(decoding: bytes, as: UTF8.self)
    }
}


final class VoiceAssistant {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()

    private let ttsQueue = DispatchQueue(
        label: "atlas.tts",
        qos: .userInitiated
    )

    private let voiceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private let kokoro: KokoroWorker

    private var state: AssistantState = .listening
    private var recording = Data()
    private var recordingSampleRate: Double = 48_000

    private var preRollBuffers: [Data] = []
    private var preRollBytes = 0

    private var speechFrames = 0
    private var silenceFrames = 0
    private var queuedAudioBuffers = 0
    private var conversationActive = false
    private var conversationTimeoutWorkItem: DispatchWorkItem?

    private var history = [
        Message(role: "system", content: Config.systemPrompt)
    ]

    init() throws {
        kokoro = try KokoroWorker()
    }

    func start() throws {
        let input = engine.inputNode
        let output = engine.outputNode

        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)

        engine.attach(player)

        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: voiceFormat
        )

        engine.connect(
            engine.mainMixerNode,
            to: output,
            format: voiceFormat
        )

        let tapFormat = input.outputFormat(forBus: 0)

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw NSError(
                domain: "Atlas",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No valid microphone format: \(tapFormat)"
                ]
            )
        }

        recordingSampleRate = tapFormat.sampleRate

        input.removeTap(onBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.handleAudio(buffer)
        }

        engine.prepare()
        try engine.start()

        let actualInput = input.outputFormat(forBus: 0)
        let actualOutput = output.inputFormat(forBus: 0)

        print(
            """
            Voice-processing audio engine started.
            Mic: \(actualInput.sampleRate) Hz, \(actualInput.channelCount) channel(s)
            Output: \(actualOutput.sampleRate) Hz, \(actualOutput.channelCount) channel(s)
            Internal voice format: 48000 Hz, 1 channel
            Say “Hey Atlas” or “Hi Atlas” to begin. Press Ctrl-C to quit.

            """
        )
    }

    private func handleAudio(_ buffer: AVAudioPCMBuffer) {
        guard
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }

        let samples = channels[0]
        let count = Int(buffer.frameLength)

        let level = rms(samples, count: count)
        let peakLevel = peak(samples, count: count)

        let voiced =
            level >= Config.speechThreshold
            || peakLevel >= Config.speechPeakThreshold

        let pcm = floatToPCM16(samples, count: count)

        var completedRecording: Data?
        var completedSampleRate: Double?
        var shouldStopPlayback = false
        var shouldCancelConversationTimeout = false

        lock.lock()

        switch state {
        case .listening:
            appendToPreRoll(pcm)

            speechFrames = voiced ? speechFrames + 1 : 0

            if speechFrames >= Config.startSpeechFrames {
                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0

                clearPreRoll()
                shouldCancelConversationTimeout = conversationActive

                print("\nListening...", terminator: "")
                fflush(stdout)
            }

        case .recording:
            recording.append(pcm)

            if voiced {
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }

            if silenceFrames >= Config.endSilenceFrames {
                if recording.count >= Config.minimumRecordingBytes {
                    completedRecording = recording
                    completedSampleRate = recordingSampleRate
                    state = .processing
                } else {
                    state = .listening
                }

                recording = Data()
                speechFrames = 0
                silenceFrames = 0
                clearPreRoll()
            }

        case .speaking:
            appendToPreRoll(pcm)

            speechFrames = voiced ? speechFrames + 1 : 0

            if speechFrames >= Config.interruptSpeechFrames {
                // Only update state in the real-time audio callback.
                // AVAudioPlayerNode.stop() must happen off this thread.
                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0
                speechFrames = 0

                clearPreRoll()
                shouldStopPlayback = true
            }

        case .processing:
            break
        }

        lock.unlock()
        if shouldCancelConversationTimeout {
            cancelConversationTimeout()
        }

        if shouldStopPlayback {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.cancelConversationTimeout()
                self.player.stop()

                self.lock.withLock {
                    self.queuedAudioBuffers = 0
                }

                print("\nInterrupted. Listening...", terminator: "")
                fflush(stdout)
            }
        }

        if let completedRecording, let completedSampleRate {
            Task {
                await processTurn(
                    pcm: completedRecording,
                    sampleRate: completedSampleRate
                )
            }
        }
    }

    private func beginConversation() {
        lock.withLock {
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            // Start a fresh LLM session for each new voice conversation.
            history = [
                Message(role: "system", content: Config.systemPrompt)
            ]
        }

        print("\nAtlas is listening.")
    }

    private func resetConversationTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.endConversation()
        }

        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = workItem
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Config.conversationTimeoutSeconds,
            execute: workItem
        )
    }

    private func endConversation() {
        let didEnd = lock.withLock { () -> Bool in
            guard conversationActive else {
                return false
            }

            conversationActive = false
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: Config.systemPrompt)
            ]

            return true
        }

        if didEnd {
            print("\nAtlas conversation ended. Say “Hey Atlas” to start again.")
        }
    }

    private func cancelConversationTimeout() {
        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil
        }
    }

    private func isWakeGreeting(_ transcript: String) -> Bool {
        let text = normalizedText(transcript)

        let wakeNames = [
            "atlas"
        ]

        for name in wakeNames {
            if text == name || text.hasPrefix("\(name) ") {
                return true
            }
        }

        for greeting in Config.wakeGreetings {
            for name in wakeNames {
                if text.hasPrefix("\(greeting) \(name)") {
                    return true
                }
            }
        }

        return false
    }

    private func textAfterWakeGreeting(_ transcript: String) -> String {
        var text = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let patterns = [
            #"(?i)^\s*(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*hey\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*hi\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*hello\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*good\s+morning\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*good\s+afternoon\s+(atlas)[\s,!.:;-]*"#,
            #"(?i)^\s*good\s+evening\s+(atlas)[\s,!.:;-]*"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)

            text = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: ""
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processTurn(
        pcm: Data,
        sampleRate: Double
    ) async {
        do {
            let wavURL = try writeTemporaryWAV(
                pcm: pcm,
                sampleRate: Int(sampleRate.rounded())
            )

            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            let transcript = try await timed("STT") {
                try await transcribe(wavURL)
            }

            guard !transcript.isEmpty else {
                print("\nNo speech recognized.")
                transitionToListening()
                return
            }

            let active = lock.withLock { conversationActive }

            var userText = transcript

            if !active {
                guard isWakeGreeting(transcript) else {
                    print("\nIgnoring: \(transcript)")
                    transitionToListening()
                    return
                }

                beginConversation()

                userText = textAfterWakeGreeting(transcript)

                if userText.isEmpty {
                    userText = "Hello"
                }
            } else {
                // User has spoken during an active session, so keep it alive.
                cancelConversationTimeout()
            }

            print("\nYou: \(userText)")
            print("Atlas: ", terminator: "")
            fflush(stdout)

            let startedAt = CACurrentMediaTime()
            var printedAnyText = false

            let fullReply = try await streamOllama(userText) {
                [weak self] sentence in

                guard let self else {
                    return
                }

                if printedAnyText {
                    print(" ", terminator: "")
                }

                print(sentence, terminator: "")
                fflush(stdout)
                printedAnyText = true

                try await self.synthesizeAndQueue(sentence)
            }

            let elapsed = CACurrentMediaTime() - startedAt

            if !printedAnyText {
                print(fullReply, terminator: "")
            }

            print()
            print(
                "[timing] LLM stream complete: "
                + "\(String(format: "%.3f", elapsed)) s"
            )

        } catch AtlasError.toolRequiredButNotInvoked {
            let fallback = """
            Something went wrong with that request. It might be beyond my capabilities. Please try again if you believe it should have worked.
            """
            print("\nAtlas: \(fallback)")
            do {
                try await synthesizeAndQueue(fallback)
            } catch {
                print("\nFallback speech error: \(error.localizedDescription)")
            }
        } catch {
            print("\nPipeline error: \(error.localizedDescription)")
            transitionToListening()
        }
    }

    private func transcribe(_ wavURL: URL) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()

        func addTextField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                    .data(using: .utf8)!
            )
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addTextField("model", "tiny")
        addTextField("language", "en")
        addTextField("response_format", "json")
        addTextField("temperature", "0")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            (
                "Content-Disposition: form-data; "
                + "name=\"file\"; filename=\"utterance.wav\"\r\n"
            ).data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Config.whisperURL)
        request.httpMethod = "POST"

        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard
            let http = response as? HTTPURLResponse,
            200..<300 ~= http.statusCode
        else {
            throw NSError(
                domain: "WhisperKit",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "WhisperKit transcription request failed."
                ]
            )
        }

        return try JSONDecoder()
            .decode(WhisperResponse.self, from: data)
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mayRequireLightTool(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        let lightWords = [
            "light",
            "lights",
            "lamp",
            "lamps"
        ]

        let actionWords = [
            "on",
            "off",
            "turn",
            "switch",
            "set",
            "status",
            "check",
            "are",
            "is",
            "whether"
        ]

        let mentionsLights = lightWords.contains {
            normalized.contains($0)
        }

        let mentionsLightAction = actionWords.contains {
            normalized.contains($0)
        }

        return mentionsLights && mentionsLightAction
    }

    private func streamOllama(
        _ userText: String,
        onSentence: @escaping (String) async throws -> Void
    ) async throws -> String {
        let mayRequireTool = mayRequireLightTool(userText)

        var messages = lock.withLock { () -> [Message] in
            var updatedHistory = history

            if mayRequireTool {
                updatedHistory.append(
                    Message(
                        role: "system",
                        content: """
                        This turn requires tool use. Your next response must contain
                        tool_calls only, with no user-facing prose, until successful
                        tool results have been provided.
                        """
                    )
                )
            }

            updatedHistory.append(
                Message(
                    role: "user",
                    content: userText
                )
            )

            history = updatedHistory
            return updatedHistory
        }

        var fullReply = ""
        var executedTool = false
        var retriedMissingToolCall = false
        let tools = try await availableTools()

        for _ in 0..<Config.maxToolLoopSteps {
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
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard
                let http = response as? HTTPURLResponse,
                200..<300 ~= http.statusCode
            else {
                throw NSError(
                    domain: "Ollama",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ollama tool request failed."
                    ]
                )
            }

            let chunk = try JSONDecoder().decode(
                OllamaStreamChunk.self,
                from: data
            )

            guard let assistantMessage = chunk.message else {
                throw NSError(
                    domain: "Ollama",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ollama returned no message."
                    ]
                )
            }

            let toolCalls = assistantMessage.toolCalls ?? []

            messages.append(
                Message(
                    role: "assistant",
                    content: assistantMessage.content,
                    toolCalls: toolCalls
                )
            )

            if !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    executedTool = true
                    let result = try await runTool(toolCall)
                    print(
                        "\n[tool result] \(toolCall.function.name): \(result)"
                    )
                    messages.append(
                        Message(
                            role: "tool",
                            content: result
                        )
                    )
                }

                continue
            }

            if mayRequireTool && !executedTool {
                if retriedMissingToolCall {
                    throw AtlasError.toolRequiredButNotInvoked
                }

                retriedMissingToolCall = true

                messages.append(
                    Message(
                        role: "user",
                        content: """
                        Validation failure: you answered a request that needs tool use \
                        without invoking a tool. Do not write a natural-language answer \
                        yet. Invoke the necessary tool or tools now.
                        """
                    )
                )

                continue
            }

            fullReply = assistantMessage.content
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let accumulator = SentenceAccumulator()

            for sentence in accumulator.append(fullReply) {
                try await onSentence(sentence)
            }

            if let remaining = accumulator.finish() {
                try await onSentence(remaining)
            }

            lock.withLock {
                history = messages

                if history.count > Config.maxHistoryMessages + 1 {
                    history.removeSubrange(
                        1..<(history.count - Config.maxHistoryMessages)
                    )
                }
            }

            return fullReply
        }

        throw NSError(
            domain: "Ollama",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tool loop exceeded its maximum number of steps."
            ]
        )
    }

    private func availableTools() async throws -> [ToolDefinition] {
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


    private func runTool(_ call: ToolCall) async throws -> String {
        let url = Config.toolServerURL
            .appendingPathComponent("tools/call")

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
            200..<300 ~= http.statusCode
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

    private func speakSentence(_ sentence: String) async throws {
        try await synthesizeAndQueue(sentence)
    }

    private func synthesizeAndQueue(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ttsQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "Atlas",
                            code: 20,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "VoiceAssistant was released."
                            ]
                        )
                    )
                    return
                }

                do {
                    let startedAt = CACurrentMediaTime()
                    let wavURL = try self.kokoro.synthesize(text: text)
                    let elapsed = CACurrentMediaTime() - startedAt

                    print(
                        "\n[timing] TTS sentence: "
                        + "\(String(format: "%.3f", elapsed)) s"
                    )

                    DispatchQueue.main.async {
                        do {
                            try self.queueWAV(wavURL)

                            try? FileManager.default.removeItem(at: wavURL)
                            continuation.resume()
                        } catch {
                            try? FileManager.default.removeItem(at: wavURL)
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func queueWAV(_ wavURL: URL) throws {
        let file = try AVAudioFile(forReading: wavURL)
        let sourceFrames = AVAudioFrameCount(file.length)

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: sourceFrames
        ) else {
            throw NSError(
                domain: "Atlas",
                code: 30,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not allocate source TTS buffer."
                ]
            )
        }

        try file.read(into: sourceBuffer)

        guard let converter = AVAudioConverter(
            from: file.processingFormat,
            to: voiceFormat
        ) else {
            throw NSError(
                domain: "Atlas",
                code: 31,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not create TTS sample-rate converter."
                ]
            )
        }

        let ratio = voiceFormat.sampleRate / file.processingFormat.sampleRate

        let outputCapacity = AVAudioFrameCount(
            Double(sourceBuffer.frameLength) * ratio
        ) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: voiceFormat,
            frameCapacity: outputCapacity
        ) else {
            throw NSError(
                domain: "Atlas",
                code: 32,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not allocate converted TTS buffer."
                ]
            )
        }

        var conversionError: NSError?
        var sourceConsumed = false

        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, outStatus in
            if sourceConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }

            sourceConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil else {
            throw conversionError ?? NSError(
                domain: "Atlas",
                code: 33,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "TTS sample-rate conversion failed."
                ]
            )
        }

        var shouldCancelConversationTimeout = false
        lock.withLock {
            if state == .processing || state == .listening {
                state = .speaking
                speechFrames = 0
                silenceFrames = 0
                shouldCancelConversationTimeout = conversationActive
            }

            queuedAudioBuffers += 1
        }

        if shouldCancelConversationTimeout {
            cancelConversationTimeout()
        }

        // Important: do NOT call player.stop() here. Each sentence gets
        // queued after the prior sentence, preserving continuous speech.
        player.scheduleBuffer(
            outputBuffer,
            at: nil,
            options: []
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.bufferFinished()
            }
        }

        player.volume = 0.9

        if !player.isPlaying {
            player.play()
        }
    }

    private func bufferFinished() {
        var shouldStartTimeout = false

        lock.withLock {
            queuedAudioBuffers = max(0, queuedAudioBuffers - 1)

            // Do not overwrite an interruption that already switched to recording.
            if queuedAudioBuffers == 0, state == .speaking {
                state = .listening
                speechFrames = 0
                silenceFrames = 0
                shouldStartTimeout = conversationActive
            }
        }

        if shouldStartTimeout {
            resetConversationTimeout()
        }
    }

    private func transitionToListening() {
        lock.withLock {
            state = .listening
            recording = Data()
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers = 0
            clearPreRoll()
        }
    }

    private func appendToPreRoll(_ pcm: Data) {
        let maxBytes = Int(
            recordingSampleRate
            * Double(Config.preRollMilliseconds)
            / 1_000.0
            * 2.0
        )

        preRollBuffers.append(pcm)
        preRollBytes += pcm.count

        while preRollBytes > maxBytes, !preRollBuffers.isEmpty {
            let removed = preRollBuffers.removeFirst()
            preRollBytes -= removed.count
        }
    }

    private func joinedPreRoll() -> Data {
        preRollBuffers.reduce(into: Data()) { result, buffer in
            result.append(buffer)
        }
    }

    private func clearPreRoll() {
        preRollBuffers.removeAll(keepingCapacity: true)
        preRollBytes = 0
    }

    private func rms(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        var sum: Float = 0

        for index in 0..<count {
            sum += samples[index] * samples[index]
        }

        return sqrt(sum / Float(count))
    }

    private func peak(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        var value: Float = 0

        for index in 0..<count {
            value = max(value, abs(samples[index]))
        }

        return value
    }

    private func floatToPCM16(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Data {
        var data = Data(capacity: count * 2)

        for index in 0..<count {
            let clipped = max(-1.0, min(1.0, samples[index]))
            var value = Int16(clipped * Float(Int16.max)).littleEndian

            withUnsafeBytes(of: &value) {
                data.append(contentsOf: $0)
            }
        }

        return data
    }

    private func writeTemporaryWAV(
        pcm: Data,
        sampleRate: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-input-\(UUID().uuidString).wav")

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16

        let byteRate =
            UInt32(sampleRate)
            * UInt32(channels)
            * UInt32(bitsPerSample / 8)

        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let riffSize = 36 + dataSize

        var wav = Data()

        wav.append("RIFF".data(using: .ascii)!)
        appendLittleEndian(riffSize, to: &wav)

        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)

        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(channels, to: &wav)
        appendLittleEndian(UInt32(sampleRate), to: &wav)
        appendLittleEndian(byteRate, to: &wav)
        appendLittleEndian(blockAlign, to: &wav)
        appendLittleEndian(bitsPerSample, to: &wav)

        wav.append("data".data(using: .ascii)!)
        appendLittleEndian(dataSize, to: &wav)
        wav.append(pcm)

        try wav.write(to: url)
        return url
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian

        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private func timed<T>(
        _ label: String,
        _ action: () async throws -> T
    ) async rethrows -> T {
        let startedAt = CACurrentMediaTime()
        let result = try await action()
        let elapsed = CACurrentMediaTime() - startedAt

        print(
            "\n[timing] \(label): "
            + "\(String(format: "%.3f", elapsed)) s"
        )

        return result
    }
}


do {
    let assistant = try VoiceAssistant()
    try assistant.start()
    RunLoop.main.run()
} catch {
    fputs(
        "Could not start Atlas: \(error.localizedDescription)\n",
        stderr
    )

    exit(1)
}