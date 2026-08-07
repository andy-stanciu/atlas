import Foundation
@preconcurrency import STTIPC

enum STTClientError: LocalizedError {
    case notConnected
    case daemonUnreachable(String)
    case daemonError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to sttd."
        case .daemonUnreachable(let message):
            return "Could not reach sttd: \(message)"
        case .daemonError(let message):
            return message
        }
    }
}

actor STTClient {
    private var connection: STTFrameConnection?
    private var pendingReply: CheckedContinuation<(type: UInt8, payload: Data), Error>?
    private var onPartialText: (@Sendable (String) -> Void)?

    init() {}

    func setPartialTextHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onPartialText = handler
    }

    func connect() async throws {
        let fd = try STTUnixSocket.connectClient(path: STTIPCConfig.socketPath)
        let connection = STTFrameConnection(fd: fd)
        self.connection = connection

        startReadLoop(connection)

        let reply = try await sendAndAwaitReply(
            connection: connection,
            type: STTRequestType.ping.rawValue,
            payload: Data()
        )

        guard reply.type == STTResponseType.pong.rawValue else {
            throw STTClientError.daemonUnreachable("Unexpected ping response")
        }
    }

    func begin() throws {
        guard let connection else {
            throw STTClientError.notConnected
        }
        try connection.writeFrame(type: STTRequestType.begin.rawValue, payload: Data())
    }

    func appendPCM16(_ pcm: Data, sourceSampleRate: Int) throws {
        guard let connection else {
            throw STTClientError.notConnected
        }

        var payload = Data()
        var rate = UInt32(sourceSampleRate).bigEndian
        withUnsafeBytes(of: &rate) { payload.append(contentsOf: $0) }
        payload.append(pcm)

        try connection.writeFrame(type: STTRequestType.append.rawValue, payload: payload)
    }

    func finish() async throws -> String {
        guard let connection else {
            throw STTClientError.notConnected
        }

        let reply = try await sendAndAwaitReply(
            connection: connection,
            type: STTRequestType.finish.rawValue,
            payload: Data()
        )

        switch STTResponseType(rawValue: reply.type) {
        case .text:
            return String(data: reply.payload, encoding: .utf8) ?? ""
        case .error:
            throw STTClientError.daemonError(
                String(data: reply.payload, encoding: .utf8) ?? "Unknown STT error"
            )
        default:
            throw STTClientError.daemonError("Unexpected finish response")
        }
    }

    func cancel() async throws {
        guard let connection else {
            throw STTClientError.notConnected
        }

        _ = try await sendAndAwaitReply(
            connection: connection,
            type: STTRequestType.cancel.rawValue,
            payload: Data()
        )
    }

    private func sendAndAwaitReply(
        connection: STTFrameConnection,
        type: UInt8,
        payload: Data
    ) async throws -> (type: UInt8, payload: Data) {
        try await withCheckedThrowingContinuation { continuation in
            self.pendingReply = continuation

            do {
                try connection.writeFrame(type: type, payload: payload)
            } catch {
                self.pendingReply = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleIncoming(_ frame: (type: UInt8, payload: Data)) {
        if frame.type == STTResponseType.partial.rawValue {
            let text = String(data: frame.payload, encoding: .utf8) ?? ""
            onPartialText?(text)
            return
        }

        guard let continuation = pendingReply else {
            return
        }

        pendingReply = nil
        continuation.resume(returning: frame)
    }

    private func handleReadLoopEnded() {
        guard let continuation = pendingReply else {
            return
        }

        pendingReply = nil
        continuation.resume(throwing: STTClientError.daemonUnreachable("Connection closed"))
    }

    private func startReadLoop(_ connection: STTFrameConnection) {
        Thread.detachNewThread { [weak self] in
            while true {
                guard let frame = try? connection.readFrame() else {
                    break
                }

                guard let self else {
                    return
                }

                Task {
                    await self.handleIncoming(frame)
                }
            }

            guard let self else {
                return
            }

            Task {
                await self.handleReadLoopEnded()
            }
        }
    }
}
