import Foundation
import STTIPC

final class ResultBox<T> {
    var value: T?
}

func runAsyncBlocking<T>(_ operation: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()

    Task {
        box.value = await operation()
        semaphore.signal()
    }

    semaphore.wait()
    return box.value!
}

/// Tracks which connection (if any) should receive push ".partial"
/// frames for the single shared recognizer's current session.
final class ActiveConnectionBox {
    private let lock = NSLock()
    private var connection: STTFrameConnection?

    func set(_ connection: STTFrameConnection?) {
        lock.lock()
        defer { lock.unlock() }
        self.connection = connection
    }

    func clearIfCurrent(_ connection: STTFrameConnection) {
        lock.lock()
        defer { lock.unlock() }
        if self.connection === connection {
            self.connection = nil
        }
    }

    func get() -> STTFrameConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }
}

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: sttd <model-folder>\n", stderr)
    exit(1)
}

let modelFolder = CommandLine.arguments[1]
let activeConnectionBox = ActiveConnectionBox()

print("[sttd] Loading WhisperKit model from \(modelFolder)...")

let recognizer: StreamingSpeechRecognizer = runAsyncBlocking {
    do {
        return try await StreamingSpeechRecognizer(
            modelFolder: modelFolder,
            partialUpdate: { update in
                guard let connection = activeConnectionBox.get() else {
                    return
                }
                try? connection.writeFrame(
                    type: STTResponseType.partial.rawValue,
                    payload: Data(update.text.utf8)
                )
            }
        )
    } catch {
        fputs("[sttd] Failed to load model: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

print("[sttd] Model loaded. Listening on \(STTIPCConfig.socketPath)")

let listenFD: Int32
do {
    listenFD = try STTUnixSocket.makeServer(path: STTIPCConfig.socketPath)
} catch {
    fputs("[sttd] Failed to bind socket: \(error)\n", stderr)
    exit(1)
}

func handleConnection(_ fd: Int32) {
    let connection = STTFrameConnection(fd: fd)

    while true {
        let frame: (type: UInt8, payload: Data)

        do {
            frame = try connection.readFrame()
        } catch {
            break
        }

        guard let requestType = STTRequestType(rawValue: frame.type) else {
            continue
        }

        switch requestType {
        case .begin:
            activeConnectionBox.set(connection)
            runAsyncBlocking {
                await recognizer.begin()
            }

        case .append:
            guard frame.payload.count >= 4 else {
                continue
            }

            let rateBytes = [UInt8](frame.payload.prefix(4))
            let sampleRate = Int(
                (UInt32(rateBytes[0]) << 24)
                    | (UInt32(rateBytes[1]) << 16)
                    | (UInt32(rateBytes[2]) << 8)
                    | UInt32(rateBytes[3])
            )
            let pcm = Data(frame.payload.dropFirst(4))

            runAsyncBlocking {
                await recognizer.appendPCM16(pcm, sourceSampleRate: sampleRate)
            }

        case .finish:
            activeConnectionBox.clearIfCurrent(connection)

            let result: Result<String, Error> = runAsyncBlocking {
                do {
                    let text = try await recognizer.finish()
                    return .success(text)
                } catch {
                    return .failure(error)
                }
            }

            switch result {
            case .success(let text):
                try? connection.writeFrame(
                    type: STTResponseType.text.rawValue,
                    payload: Data(text.utf8)
                )
            case .failure(let error):
                try? connection.writeFrame(
                    type: STTResponseType.error.rawValue,
                    payload: Data(error.localizedDescription.utf8)
                )
            }

        case .cancel:
            activeConnectionBox.clearIfCurrent(connection)
            runAsyncBlocking {
                await recognizer.cancel()
            }
            try? connection.writeFrame(type: STTResponseType.ok.rawValue, payload: Data())

        case .ping:
            try? connection.writeFrame(type: STTResponseType.pong.rawValue, payload: Data())
        }
    }

    activeConnectionBox.clearIfCurrent(connection)
    connection.close()
}

print("[sttd] Ready.")

while true {
    guard let clientFD = try? STTUnixSocket.accept(listenFD) else {
        continue
    }

    Thread.detachNewThread {
        handleConnection(clientFD)
    }
}
