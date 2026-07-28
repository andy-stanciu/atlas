import Foundation

final class KokoroWorker: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()

    init() throws {
        process.executableURL = URL(
            fileURLWithPath: Config.pythonExecutable
        )

        process.arguments = [Config.ttsWorkerScript]
        process.standardInput = stdin
        process.standardOutput = stdout
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
                .appendingPathComponent(
                    "voice-tts-\(UUID().uuidString).wav"
                )

            let payload = [
                "text": text,
                "output_path": outputURL.path,
            ]

            let data = try JSONSerialization.data(
                withJSONObject: payload
            )

            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data([0x0A]))

            let responseLine = try readLine()
            let responseData = Data(responseLine.utf8)

            guard
                let response = try JSONSerialization.jsonObject(
                    with: responseData
                ) as? [String: Any],
                response["ok"] as? Bool == true,
                FileManager.default.fileExists(
                    atPath: outputURL.path
                )
            else {
                let errorMessage =
                    (
                        try? JSONSerialization.jsonObject(
                            with: responseData
                        ) as? [String: Any]
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
            let data = try stdout.fileHandleForReading.read(
                upToCount: 1
            )

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