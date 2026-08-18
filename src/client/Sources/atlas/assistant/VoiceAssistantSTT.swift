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

    func rotateIdleRecognizerSession() {
        let carryoverBytes =
            Int(
                recordingSampleRate
                    * Double(Config.idleRotationCarryoverMilliseconds)
                    / 1_000
                    * 2
            ) / 2 * 2
        let carryover =
            recording.count > carryoverBytes
            ? Data(recording.suffix(carryoverBytes))
            : recording
        let rate = Int(recordingSampleRate.rounded())
        let rotated = recording
        recording = carryover

        let previous = recognizerFeedChain
        let client = sttClient
        let rotationTask = Task { () -> String in
            await previous.value
            guard let client else {
                return ""
            }
            let transcript = (try? await client.finish()) ?? ""
            try? await client.begin()
            try? await client.appendPCM16(carryover, sourceSampleRate: rate)
            return transcript
        }
        recognizerFeedChain = Task {
            _ = await rotationTask.value
        }
        Task { [weak self] in
            let transcript = await rotationTask.value
            guard let self, !transcript.isEmpty else {
                return
            }
            await self.processRotatedTurn(
                pcm: rotated,
                sampleRate: Double(rate),
                transcript: transcript
            )
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
