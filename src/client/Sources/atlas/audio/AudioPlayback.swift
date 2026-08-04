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
    private let player: AVAudioPlayerNode
    private let kokoro: KokoroWorker
    private let queue: DispatchQueue
    private let voiceFormat: AVAudioFormat

    private let beginSpeaking: (PlaybackPurpose) -> Bool
    private let finishSpeaking: (PlaybackPurpose) -> Void
    private let beginScheduledSpeech: () -> Bool

    init(
        player: AVAudioPlayerNode,
        kokoro: KokoroWorker,
        queue: DispatchQueue,
        voiceFormat: AVAudioFormat,
        beginSpeaking: @escaping (PlaybackPurpose) -> Bool,
        finishSpeaking: @escaping (PlaybackPurpose) -> Void,
        beginScheduledSpeech: @escaping () -> Bool
    ) {
        self.player = player
        self.kokoro = kokoro
        self.queue = queue
        self.voiceFormat = voiceFormat
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
        let wavURL = try await synthesize(text)

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    try? FileManager.default.removeItem(at: wavURL)
                    continuation.resume(returning: .notStarted)
                    return
                }

                do {
                    try self.playScheduledWAV(
                        wavURL,
                        continuation: continuation,
                        onStarted: onStarted
                    )
                } catch {
                    try? FileManager.default.removeItem(at: wavURL)
                    continuation.resume(returning: .failed)
                }
            }
        }
    }

    private func queueSpeech(
        _ text: String,
        purpose: PlaybackPurpose,
        turnID: UUID,
        isCurrentTurn: @escaping @Sendable (UUID) -> Bool
    ) async throws {
        let wavURL = try await synthesize(text)

        guard isCurrentTurn(turnID) else {
            try? FileManager.default.removeItem(at: wavURL)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    try? FileManager.default.removeItem(at: wavURL)
                    continuation.resume()
                    return
                }

                guard isCurrentTurn(turnID) else {
                    try? FileManager.default.removeItem(at: wavURL)
                    continuation.resume()
                    return
                }

                do {
                    try self.queueWAV(
                        wavURL,
                        purpose: purpose,
                        turnID: turnID,
                        isCurrentTurn: isCurrentTurn
                    )
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: wavURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func synthesize(_ text: String) async throws -> URL {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [kokoro] in
                do {
                    let startedAt = CACurrentMediaTime()
                    let wavURL = try kokoro.synthesize(text: text)
                    let elapsed = CACurrentMediaTime() - startedAt

                    print(
                        "\n[timing] TTS sentence: "
                            + "\(String(format: "%.3f", elapsed)) s"
                    )

                    continuation.resume(returning: wavURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func queueWAV(
        _ wavURL: URL,
        purpose: PlaybackPurpose,
        turnID: UUID,
        isCurrentTurn: @escaping @Sendable (UUID) -> Bool
    ) throws {
        let outputBuffer = try makeOutputBuffer(from: wavURL)

        guard isCurrentTurn(turnID) else {
            try? FileManager.default.removeItem(at: wavURL)
            return
        }

        guard beginSpeaking(purpose) else {
            try? FileManager.default.removeItem(at: wavURL)
            return
        }

        player.scheduleBuffer(
            outputBuffer,
            at: nil,
            options: []
        ) { [weak self] in
            try? FileManager.default.removeItem(at: wavURL)
            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                self?.finishSpeaking(purpose)
            }
        }

        player.volume = Config.speakingVolume
        player.play()
    }

    private func playScheduledWAV(
        _ wavURL: URL,
        continuation: CheckedContinuation<SpeechPlaybackOutcome, Never>,
        onStarted: @escaping @Sendable () async -> Void
    ) throws {
        let outputBuffer = try makeOutputBuffer(from: wavURL)

        guard beginScheduledSpeech() else {
            try? FileManager.default.removeItem(at: wavURL)
            continuation.resume(returning: .notStarted)
            return
        }

        player.scheduleBuffer(
            outputBuffer,
            at: nil,
            options: []
        ) { [weak self] in
            try? FileManager.default.removeItem(at: wavURL)

            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                self?.finishSpeaking(.scheduledSpeech)
                continuation.resume(returning: .completed)
            }
        }

        player.volume = Config.speakingVolume
        player.play()

        Task {
            await onStarted()
        }
    }

    private func makeOutputBuffer(
        from wavURL: URL
    ) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: wavURL)
        let sourceFrames = AVAudioFrameCount(file.length)

        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: sourceFrames
            )
        else {
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

        guard
            let converter = AVAudioConverter(
                from: file.processingFormat,
                to: voiceFormat
            )
        else {
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
        let outputCapacity =
            AVAudioFrameCount(
                Double(sourceBuffer.frameLength) * ratio
            ) + 1

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: voiceFormat,
                frameCapacity: outputCapacity
            )
        else {
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
        ) { _, outputStatus in
            if sourceConsumed {
                outputStatus.pointee = .noDataNow
                return nil
            }

            sourceConsumed = true
            outputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil else {
            throw conversionError
                ?? NSError(
                    domain: "Atlas",
                    code: 33,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "TTS sample-rate conversion failed."
                    ]
                )
        }

        return outputBuffer
    }
}
