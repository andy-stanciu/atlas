import AVFoundation
import Foundation
import QuartzCore

enum SpeechPlaybackOutcome: Equatable {
    case completed
    case interrupted
    case notStarted
    case failed
}

enum PlaybackPurpose: Equatable {
    case thinkingFiller
    case assistantReply
    case scheduledSpeech
}

final class AudioPlayback: @unchecked Sendable {
    private let satellite: SatelliteLink
    private let kokoro: KokoroWorker
    private let queue: DispatchQueue

    private let beginSpeaking: (PlaybackPurpose) -> Bool
    private let finishSpeaking: (PlaybackPurpose) -> Void
    private let beginScheduledSpeech: () -> Bool

    init(
        satellite: SatelliteLink,
        kokoro: KokoroWorker,
        queue: DispatchQueue,
        beginSpeaking: @escaping (PlaybackPurpose) -> Bool,
        finishSpeaking: @escaping (PlaybackPurpose) -> Void,
        beginScheduledSpeech: @escaping () -> Bool
    ) {
        self.satellite = satellite
        self.kokoro = kokoro
        self.queue = queue
        self.beginSpeaking = beginSpeaking
        self.finishSpeaking = finishSpeaking
        self.beginScheduledSpeech = beginScheduledSpeech
    }

    func queueThinkingFiller(
        _ text: String,
        for turnID: UUID,
        isCurrentTurn: @escaping @Sendable (UUID) -> Bool
    ) async throws {
        try await queueSpeech(
            text,
            purpose: .thinkingFiller,
            turnID: turnID,
            isCurrentTurn: isCurrentTurn
        )
    }

    func queueAssistantReply(
        _ text: String,
        for turnID: UUID,
        isCurrentTurn: @escaping @Sendable (UUID) -> Bool
    ) async throws {
        try await queueSpeech(
            text,
            purpose: .assistantReply,
            turnID: turnID,
            isCurrentTurn: isCurrentTurn
        )
    }

    func speakScheduled(
        _ text: String,
        onStarted: @escaping @Sendable () async -> Void
    ) async throws -> SpeechPlaybackOutcome {
        let pcm = try await synthesize(text)

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .notStarted)
                    return
                }
                self.playScheduledPCM(
                    pcm,
                    continuation: continuation,
                    onStarted: onStarted
                )
            }
        }
    }

    private func queueSpeech(
        _ text: String,
        purpose: PlaybackPurpose,
        turnID: UUID,
        isCurrentTurn: @escaping @Sendable (UUID) -> Bool
    ) async throws {
        let pcm = try await synthesize(text)

        guard isCurrentTurn(turnID) else {
            return
        }

        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, isCurrentTurn(turnID) else {
                    continuation.resume()
                    return
                }
                self.queuePCM(
                    pcm,
                    purpose: purpose,
                    turnID: turnID,
                    isCurrentTurn: isCurrentTurn
                )
                continuation.resume()
            }
        }
    }

    /// Synthesizes one sentence on the PC, returning 24 kHz s16le PCM.
    private func synthesize(_ text: String) async throws -> Data {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [kokoro] in
                do {
                    let startedAt = CACurrentMediaTime()
                    let pcm = try kokoro.synthesize(text: text)
                    let elapsed = CACurrentMediaTime() - startedAt

                    Log.timing(
                        "TTS sentence: "
                            + "\(String(format: "%.3f", elapsed)) s"
                    )

                    continuation.resume(returning: pcm)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func queuePCM(
        _ pcm: Data,
        purpose: PlaybackPurpose,
        turnID: UUID,
        isCurrentTurn: @escaping @Sendable (UUID) -> Bool
    ) {
        let output = scalePCM(pcm)

        guard isCurrentTurn(turnID) else {
            return
        }

        guard beginSpeaking(purpose) else {
            return
        }

        satellite.enqueue(pcm: output) { [weak self] _ in
            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                self?.finishSpeaking(purpose)
            }
        }
    }

    private func playScheduledPCM(
        _ pcm: Data,
        continuation: CheckedContinuation<SpeechPlaybackOutcome, Never>,
        onStarted: @escaping @Sendable () async -> Void
    ) {
        let output = scalePCM(pcm)

        guard beginScheduledSpeech() else {
            continuation.resume(returning: .notStarted)
            return
        }

        Task { [weak self] in
            await onStarted()
            self?.satellite.enqueue(pcm: output) { played in
                DispatchQueue.global(
                    qos: .userInitiated
                ).async {
                    self?.finishSpeaking(.scheduledSpeech)
                    continuation.resume(
                        returning: played ? .completed : .interrupted
                    )
                }
            }
        }
    }

    /// Applies speakingVolume to 24 kHz s16le PCM from the TTS server.
    /// The server sends native-rate audio, so no resampling is needed.
    private func scalePCM(_ pcm: Data) -> Data {
        var output = Data(capacity: pcm.count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let scaled = max(
                    -32768,
                    min(
                        32767,
                        Int32(
                            (Float(sample) * Config.speakingVolume)
                                .rounded()
                        )
                    )
                )
                var value = Int16(scaled).littleEndian
                withUnsafeBytes(of: &value) {
                    output.append(contentsOf: $0)
                }
            }
        }
        return output
    }
}
