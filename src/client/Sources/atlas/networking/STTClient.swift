import Foundation

enum STTClientError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the Atlas STT server."
        case .connectionFailed(let message):
            return "Could not reach the Atlas STT server: \(message)"
        case .serverError(let message):
            return message
        }
    }
}

actor STTClient {
    private static let targetSampleRate = 24_000
    private static let frameSamples = 480  // 20ms @ 24kHz, matches the server's encoder step
    private static let sttDelaySeconds = 0.5  // kyutai/stt-1b-en_fr's inherent algorithmic delay
    private static let flushFrames = Int((sttDelaySeconds / 0.02).rounded(.up)) + 1
    private static let quietThreshold: CFAbsoluteTime = 0.15  // how long transcript must be stable before we return
    private static let pollInterval: UInt64 = 30_000_000  // 30ms
    private static let pauseScoreAttackAlpha: Float = 0.5
    private static let pauseScoreReleaseAlpha: Float = 0.1

    private let serverURL: URL
    private let apiKey: String
    private let onPauseScoreUpdate: (@Sendable (Double) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var transcript = ""
    private var lastServerError: Error?
    private var lastWordReceivedAt: CFAbsoluteTime?
    private var smoothedPauseScore: Float = 0
    private var pendingSamples: [Float] = []

    private var totalInputSamplesConsumed = 0
    private var nextOutputIndex = 0
    private var lastRawSample: Float = 0

    init(
        host: String = Config.sttServerHost,
        port: Int = Config.sttServerPort,
        apiKey: String = Config.sttServerAPIKey,
        onPauseScoreUpdate: (@Sendable (Double) -> Void)? = nil
    ) {
        self.serverURL = URL(string: "ws://\(host):\(port)/api/asr-streaming")!
        self.apiKey = apiKey
        self.onPauseScoreUpdate = onPauseScoreUpdate
    }

    func verifyReachable() async throws {
        try await begin()
        await teardown()
    }

    func begin() async throws {
        await teardown()

        var request = URLRequest(url: serverURL)
        request.setValue(apiKey, forHTTPHeaderField: "kyutai-api-key")

        let newTask = URLSession.shared.webSocketTask(with: request)
        newTask.resume()

        guard let firstMessage = try await receiveDecoded(newTask) else {
            newTask.cancel(with: .goingAway, reason: nil)
            throw STTClientError.connectionFailed(
                "Connection closed before a Ready message arrived")
        }
        guard case .map(let fields) = firstMessage else {
            newTask.cancel(with: .goingAway, reason: nil)
            throw STTClientError.connectionFailed("Unexpected startup message shape")
        }
        guard case .string("Ready") = fields["type"] ?? .null else {
            newTask.cancel(with: .goingAway, reason: nil)
            throw STTClientError.connectionFailed("Did not receive a Ready message")
        }

        task = newTask
        transcript = ""
        lastServerError = nil
        lastWordReceivedAt = nil
        smoothedPauseScore = 0
        pendingSamples = []
        totalInputSamplesConsumed = 0
        nextOutputIndex = 0
        lastRawSample = 0
        onPauseScoreUpdate?(0)

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(newTask)
        }
    }

    func appendPCM16(_ pcm: Data, sourceSampleRate: Int) async throws {
        guard let task else {
            throw STTClientError.notConnected
        }

        pendingSamples.append(contentsOf: resample(pcm, sourceSampleRate: sourceSampleRate))

        while pendingSamples.count >= Self.frameSamples {
            let frame = Array(pendingSamples.prefix(Self.frameSamples))
            pendingSamples.removeFirst(Self.frameSamples)
            try await send(frame: frame, task: task)
        }
    }

    func finish() async throws -> String {
        guard let task else {
            throw STTClientError.notConnected
        }

        let silence = [Float](repeating: 0, count: Self.frameSamples)
        for _ in 0..<Self.flushFrames {
            try await send(frame: silence, task: task)
        }

        let flushSentAt = CFAbsoluteTimeGetCurrent()
        let deadline = flushSentAt + Self.sttDelaySeconds + 0.3

        while CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(nanoseconds: Self.pollInterval)
            let quietSince = lastWordReceivedAt ?? flushSentAt
            if CFAbsoluteTimeGetCurrent() - quietSince >= Self.quietThreshold {
                break
            }
        }

        let result = transcript
        let error = lastServerError
        await teardown()

        if let error {
            throw error
        }
        return result
    }

    func cancel() async throws {
        await teardown()
    }

    // MARK: - Internals

    private func send(frame: [Float], task: URLSessionWebSocketTask) async throws {
        let message = MsgPackValue.map([
            "type": .string("Audio"),
            "pcm": .array(frame.map { .float($0) }),
        ])
        try await task.send(.data(MsgPack.encode(message)))
    }

    private func runReceiveLoop(_ task: URLSessionWebSocketTask) async {
        while true {
            guard let value = try? await receiveDecoded(task) else {
                return
            }
            guard case .map(let fields) = value else {
                continue
            }
            guard case .string(let type) = fields["type"] ?? .null else {
                continue
            }

            switch type {
            case "Word":
                if case .string(let text) = fields["text"] ?? .null {
                    transcript += (transcript.isEmpty ? "" : " ") + text
                    lastWordReceivedAt = CFAbsoluteTimeGetCurrent()
                }
            case "Step":
                guard case .array(let prs) = fields["prs"] ?? .null, prs.count >= 3 else { break }
                guard case .double(let pauseRaw) = prs[2] else { break }
                updatePauseScore(Float(pauseRaw))
            case "Error":
                if case .string(let message) = fields["message"] ?? .null {
                    lastServerError = STTClientError.serverError(message)
                }
            default:
                break
            }
        }
    }

    private func updatePauseScore(_ raw: Float) {
        let alpha =
            raw > smoothedPauseScore ? Self.pauseScoreAttackAlpha : Self.pauseScoreReleaseAlpha
        smoothedPauseScore += alpha * (raw - smoothedPauseScore)
        onPauseScoreUpdate?(Double(smoothedPauseScore))
    }

    private func receiveDecoded(_ task: URLSessionWebSocketTask) async throws -> MsgPackValue? {
        guard case .data(let data) = try await task.receive() else {
            return nil
        }
        return MsgPack.decode(data)
    }

    private func teardown() async {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func resample(_ pcm: Data, sourceSampleRate: Int) -> [Float] {
        let sampleCount = pcm.count / 2
        var input = [Float](repeating: 0, count: sampleCount)
        pcm.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                input[i] = Float(int16Buffer[i]) / 32_768.0
            }
        }

        guard sourceSampleRate != Self.targetSampleRate, !input.isEmpty else {
            totalInputSamplesConsumed += input.count
            lastRawSample = input.last ?? lastRawSample
            return input
        }

        let divisor = gcd(sourceSampleRate, Self.targetSampleRate)
        let upsampleFactor = Self.targetSampleRate / divisor  // L
        let downsampleFactor = sourceSampleRate / divisor  // M

        var output: [Float] = []
        let chunkStart = totalInputSamplesConsumed

        while true {
            let inputPositionNumerator = nextOutputIndex * downsampleFactor
            let globalInputIndex = inputPositionNumerator / upsampleFactor
            let remainder = inputPositionNumerator % upsampleFactor
            let localIndex = globalInputIndex - chunkStart

            guard localIndex < input.count else { break }

            let frac = Float(remainder) / Float(upsampleFactor)
            let s0 = localIndex <= 0 ? lastRawSample : input[localIndex - 1]
            let s1 = input[max(localIndex, 0)]
            output.append(s0 + (s1 - s0) * frac)
            nextOutputIndex += 1
        }

        totalInputSamplesConsumed += input.count
        lastRawSample = input.last ?? lastRawSample
        return output
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return max(x, 1)
    }
}
