import AVFoundation
import Foundation
import QuartzCore

extension VoiceAssistant {

    func configureAudioEngine() throws {
        let input = engine.inputNode
        let output = engine.outputNode

        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)

        engine.attach(player)

        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: voiceFormat
        )

        engine.connect(
            engine.mainMixerNode,
            to: output,
            format: voiceFormat
        )

        let tapFormat = input.outputFormat(forBus: 0)

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw NSError(
                domain: "Atlas",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No valid microphone format: \(tapFormat)"
                ]
            )
        }

        recordingSampleRate = tapFormat.sampleRate
        input.removeTap(onBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.handleAudio(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func handleAudio(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }

        let samples = channels[0]
        let count = Int(buffer.frameLength)

        let voiced =
            rms(samples, count: count) >= Config.speechThreshold
            || peak(samples, count: count) >= Config.speechPeakThreshold

        let pcm = floatToPCM16(samples, count: count)

        var completedRecording: Data?
        var completedSampleRate: Double?
        var shouldStopPlayback = false
        var shouldCancelTimeout = false

        guard lock.try() else {
            return
        }

        defer {
            lock.unlock()
        }

        switch state {
        case .listening:
            appendToPreRoll(pcm)
            speechFrames = voiced ? speechFrames + 1 : 0

            if speechFrames >= Config.startSpeechFrames {
                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0
                clearPreRoll()
                shouldCancelTimeout = conversationActive
                beginRecognizerSession(preRoll: recording)
                Log.blank()
                Log.system("Listening...", terminator: "")
            }

        case .recording:
            recording.append(pcm)
            let rate = Int(recordingSampleRate.rounded())
            feedRecognizer { client in
                try? await client.appendPCM16(pcm, sourceSampleRate: rate)
            }

            if voiced {
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }

            if silenceFrames >= Config.endSilenceFrames {
                if recording.count >= Config.minimumRecordingBytes {
                    completedRecording = recording
                    completedSampleRate = recordingSampleRate
                    state = .processing
                } else {
                    cancelRecognizerSession()
                    state = .listening
                }

                recording = Data()
                speechFrames = 0
                silenceFrames = 0
                clearPreRoll()
            }

        case .speaking:
            appendToPreRoll(pcm)
            speechFrames = voiced ? speechFrames + 1 : 0
            let elapsedSinceSpeaking = CACurrentMediaTime() - speakingStartedAt

            if speechFrames >= Config.interruptSpeechFrames,
                elapsedSinceSpeaking >= Config.interruptGracePeriodSeconds
            {
                let mergeIntoPendingTurn =
                    currentPlaybackPurpose == .thinkingFiller

                if mergeIntoPendingTurn {
                    pendingMergedText = activeTurnText
                } else {
                    pendingMergedText = nil
                }

                generationTask?.cancel()
                activeTurnID = nil
                activeTurnText = nil
                activeTurnSpeaker = nil
                currentPlaybackPurpose = nil

                state = .recording
                recording = joinedPreRoll()
                silenceFrames = 0
                speechFrames = 0
                clearPreRoll()
                beginRecognizerSession(preRoll: recording)
                shouldStopPlayback = true
                shouldEndConversationAfterSpeech = false
            }

        case .processing:
            break
        }

        if shouldCancelTimeout {
            cancelConversationTimeout()
        }

        if shouldStopPlayback {
            ttsQueue.async { [weak self] in
                guard let self else {
                    return
                }

                self.cancelConversationTimeout()
                self.player.stop()

                self.lock.withLock {
                    self.queuedAudioBuffers = 0
                    self.currentPlaybackPurpose = nil
                }
                Log.blank()
                Log.system("Interrupted. Listening...", terminator: "")
            }
        }

        if let completedRecording, let completedSampleRate {
            Task {
                await self.processTurn(
                    pcm: completedRecording,
                    sampleRate: completedSampleRate
                )
            }
        }
    }

    func appendToPreRoll(_ pcm: Data) {
        let maxBytes = Int(
            recordingSampleRate
                * Double(Config.preRollMilliseconds)
                / 1_000
                * 2
        )

        preRollBuffers.append(pcm)
        preRollBytes += pcm.count

        while preRollBytes > maxBytes, !preRollBuffers.isEmpty {
            let removed = preRollBuffers.removeFirst()
            preRollBytes -= removed.count
        }
    }

    func joinedPreRoll() -> Data {
        preRollBuffers.reduce(into: Data()) { result, buffer in
            result.append(buffer)
        }
    }

    func clearPreRoll() {
        preRollBuffers.removeAll(keepingCapacity: true)
        preRollBytes = 0
    }

    func rms(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        var sum: Float = 0

        for index in 0..<count {
            sum += samples[index] * samples[index]
        }

        return sqrt(sum / Float(count))
    }

    func peak(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        var value: Float = 0

        for index in 0..<count {
            value = max(value, abs(samples[index]))
        }

        return value
    }

    func floatToPCM16(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Data {
        var data = Data(capacity: count * 2)

        for index in 0..<count {
            let clipped = max(-1, min(1, samples[index]))
            var value = Int16(
                clipped * Float(Int16.max)
            ).littleEndian

            withUnsafeBytes(of: &value) {
                data.append(contentsOf: $0)
            }
        }

        return data
    }
}
