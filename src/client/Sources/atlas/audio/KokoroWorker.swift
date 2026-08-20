import Foundation
import Network

final class KokoroWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var nextRequestID: UInt32 = 1

    /// Synthesizes text, returning 24 kHz s16le mono PCM.
    /// Serialized: one outstanding request at a time, matching the
    /// ordered sentence queue in AudioPlayback.
    func synthesize(text: String) throws -> Data {
        try lock.withLock {
            let requestID = nextRequestID
            nextRequestID &+= 1

            var lastError: Error?
            for attempt in 0...1 {
                do {
                    let connection = try activeConnection()
                    try sendRequest(
                        connection,
                        id: requestID,
                        text: text
                    )
                    return try readResponse(
                        connection,
                        id: requestID
                    )
                } catch {
                    lastError = error
                    dropConnection()
                    guard attempt == 0 else { break }
                }
            }
            throw lastError
                ?? NSError(domain: "Kokoro", code: 5, userInfo: nil)
        }
    }

    // MARK: - Connection

    private func activeConnection() throws -> NWConnection {
        if let connection, connection.state == .ready {
            return connection
        }
        dropConnection()

        let connection = NWConnection(
            host: NWEndpoint.Host(Config.ttsServerHost),
            port: NWEndpoint.Port(integerLiteral: UInt16(Config.ttsServerPort)),
            using: .tcp
        )
        let semaphore = DispatchSemaphore(value: 0)
        var ready = false
        connection.stateUpdateHandler = { state in
            if state == .ready {
                ready = true
                semaphore.signal()
            } else if case .failed = state {
                semaphore.signal()
            } else if case .cancelled = state {
                semaphore.signal()
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        let result = semaphore.wait(timeout: .now() + 3)
        guard result == .success, ready else {
            connection.cancel()
            throw NSError(
                domain: "Kokoro",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not connect to TTS server at "
                        + "\(Config.ttsServerHost):\(Config.ttsServerPort)."
                ]
            )
        }
        self.connection = connection
        return connection
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Wire I/O

    private func sendRequest(
        _ connection: NWConnection,
        id: UInt32,
        text: String
    ) throws {
        let payload = try JSONSerialization.data(
            withJSONObject: ["id": id, "text": text]
        )
        var frame = Data(capacity: 5 + payload.count)
        var length = UInt32(payload.count).littleEndian
        frame.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })
        frame.append(0x01)
        frame.append(payload)

        try sendAll(connection, data: frame)
    }

    private func readResponse(
        _ connection: NWConnection,
        id: UInt32
    ) throws -> Data {
        var pcm = Data()
        while true {
            let header = try receiveExact(connection, length: 5)
            let length = header.withUnsafeBytes {
                $0.load(as: UInt32.self)
            }
            let frameType = header[4]
            let payload = try receiveExact(
                connection,
                length: Int(length)
            )

            guard payload.count >= 4 else { continue }
            let frameID = payload.withUnsafeBytes {
                $0.load(as: UInt32.self)
            }
            guard frameID == id else { continue }

            switch frameType {
            case 0x02:
                pcm.append(payload.dropFirst(8))
            case 0x03:
                return pcm
            case 0x04:
                let message = String(
                    decoding: payload.dropFirst(4),
                    as: UTF8.self
                )
                throw NSError(
                    domain: "Kokoro",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Kokoro generation failed: \(message)"
                    ]
                )
            default:
                continue
            }
        }
    }

    private func sendAll(
        _ connection: NWConnection,
        data: Data
    ) throws {
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<data.count)
            let written = try withUnsafeSend(connection, content: chunk)
            offset += written
        }
    }

    private func withUnsafeSend(
        _ connection: NWConnection,
        content: Data
    ) throws -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(
            content: content,
            completion: .contentProcessed { error in
                sendError = error
                semaphore.signal()
            }
        )
        let result = semaphore.wait(timeout: .now() + 5)
        guard result == .success else {
            throw NSError(domain: "Kokoro", code: 7, userInfo: nil)
        }
        if let sendError {
            throw sendError
        }
        return content.count
    }

    private func receiveExact(
        _ connection: NWConnection,
        length: Int
    ) throws -> Data {
        var data = Data()
        while data.count < length {
            let semaphore = DispatchSemaphore(value: 0)
            var received: Data?
            var receiveError: Error?
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: length - data.count
            ) { content, _, isComplete, error in
                received = content
                receiveError =
                    error
                    ?? (isComplete
                        ? NSError(domain: "Kokoro", code: 8, userInfo: nil)
                        : nil)
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + 30)
            guard result == .success else {
                throw NSError(
                    domain: "Kokoro",
                    code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Timed out waiting for TTS audio."
                    ]
                )
            }
            if let receiveError {
                throw receiveError
            }
            if let received {
                data.append(received)
            }
        }
        return data
    }
}
