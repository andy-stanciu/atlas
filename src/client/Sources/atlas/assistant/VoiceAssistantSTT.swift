import Foundation
import QuartzCore

extension VoiceAssistant {

    func feedRecognizer(
        _ operation: @escaping @Sendable (STTClient) async -> Void
    ) {
        let previous = recognizerFeedChain
        let client = sttClient

        recognizerFeedChain = Task {
            await previous.value
            guard let client else {
                return
            }
            await operation(client)
        }
    }

    func beginRecognizerSession(preRoll: Data) {
        let rate = Int(recordingSampleRate.rounded())
        feedRecognizer { client in
            try? await client.begin()
            try? await client.appendPCM16(preRoll, sourceSampleRate: rate)
        }
    }

    func cancelRecognizerSession() {
        feedRecognizer { client in
            try? await client.cancel()
        }
    }

    func handleLiveTranscript(_ text: String) {
        lock.withLock {
            consoleTranscript.showPartial(text)
        }
    }

    func timed<T>(
        _ label: String,
        _ action: () async throws -> T
    ) async rethrows -> T {
        let startedAt = CACurrentMediaTime()
        let result = try await action()
        let elapsed = CACurrentMediaTime() - startedAt

        Log.timing(
            "\(label): "
                + "\(String(format: "%.3f", elapsed)) s"
        )

        return result
    }
}
