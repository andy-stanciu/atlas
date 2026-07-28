import AVFoundation
import Foundation
import QuartzCore

enum SpeechPurpose {
    case normalResponse
    case reminder
}

struct SpeechPlaybackResult {
    let completed: Bool
    let interrupted: Bool
}

final class AudioPlayback: @unchecked Sendable {
    private let player: AVAudioPlayerNode
    private let kokoro: KokoroWorker
    private let queue: DispatchQueue
    private let voiceFormat: AVAudioFormat

    private let beginSpeaking: () -> Bool
    private let finishSpeaking: () -> Void

    init(
        player: AVAudioPlayerNode,
        kokoro: KokoroWorker,
        queue: DispatchQueue,
        voiceFormat: AVAudioFormat,
        beginSpeaking: @escaping () -> Bool,
        finishSpeaking: @escaping () -> Void
    ) {
        self.player = player
        self.kokoro = kokoro
        self.queue = queue
        self.voiceFormat = voiceFormat
        self.beginSpeaking = beginSpeaking
        self.finishSpeaking = finishSpeaking
    }

    func queueNormalSpeech(_ text: String) async throws {
        let wavURL = try await synthesize(text)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: wavURL)
                return
            }

            do {
                try self.queueWAV(wavURL)
            } catch {
                try? FileManager.default.removeItem(at: wavURL)
                print(
                    "\nSpeech queue error: "
                        + error.localizedDescription
                )
            }
        }
    }

    func speak(
        _ text: String,
        purpose: SpeechPurpose
    ) async throws -> SpeechPlaybackResult {
        let wavURL = try await synthesize(text)

        return try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<SpeechPlaybackResult, Error>
            ) in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    try? FileManager.default.removeItem(at: wavURL)

                    continuation.resume(
                        returning: SpeechPlaybackResult(
                            completed: false,
                            interrupted: true
                        )
                    )

                    return
                }

                do {
                    try self.playReminderWAV(
                        wavURL,
                        continuation: continuation
                    )
                } catch {
                    try? FileManager.default.removeItem(at: wavURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func synthesize(_ text: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
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

    private func queueWAV(_ wavURL: URL) throws {
        let outputBuffer = try makeOutputBuffer(from: wavURL)

        guard beginSpeaking() else {
            try? FileManager.default.removeItem(at: wavURL)
            return
        }

        player.scheduleBuffer(
            outputBuffer,
            at: nil,
            options: []
        ) { [weak self] in
            try? FileManager.default.removeItem(at: wavURL)

            DispatchQueue.main.async {
                self?.finishSpeaking()
            }
        }

        player.volume = 0.9

        if !player.isPlaying {
            player.play()
        }
    }

    private func playReminderWAV(
        _ wavURL: URL,
        continuation: CheckedContinuation<SpeechPlaybackResult, Error>
    ) throws {
        let outputBuffer = try makeOutputBuffer(from: wavURL)

        guard beginSpeaking() else {
            try? FileManager.default.removeItem(at: wavURL)

            continuation.resume(
                returning: SpeechPlaybackResult(
                    completed: false,
                    interrupted: true
                )
            )

            return
        }

        player.scheduleBuffer(
            outputBuffer,
            at: nil,
            options: []
        ) { [weak self] in
            try? FileManager.default.removeItem(at: wavURL)

            DispatchQueue.main.async {
                self?.finishSpeaking()

                continuation.resume(
                    returning: SpeechPlaybackResult(
                        completed: true,
                        interrupted: false
                    )
                )
            }
        }

        player.volume = 0.9

        if !player.isPlaying {
            player.play()
        }
    }

    private func makeOutputBuffer(
        from wavURL: URL
    ) throws -> AVAudioPCMBuffer {
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

        let ratio = voiceFormat.sampleRate
            / file.processingFormat.sampleRate

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