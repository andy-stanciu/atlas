import Foundation
import QuartzCore

extension VoiceAssistant {

    func handleAudio(samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else {
            return
        }

        let rmsValue = rms(samples, count: count)
        let peakValue = peak(samples, count: count)
        let voiced =
            rmsValue >= Config.speechThreshold
            || peakValue >= Config.speechPeakThreshold

        if Config.debugAudioLevels {
            micDebugFrames += 1
            micDebugMaxRMS = max(micDebugMaxRMS, rmsValue)
            micDebugMaxPeak = max(micDebugMaxPeak, peakValue)
            if micDebugFrames >= 100 {
                Log.system(
                    String(
                        format:
                            "mic levels: max rms %.4f (thr %.3f), "
                            + "max peak %.4f (thr %.3f)",
                        Double(micDebugMaxRMS),
                        Double(Config.speechThreshold),
                        Double(micDebugMaxPeak),
                        Double(Config.speechPeakThreshold)
                    )
                )
                micDebugFrames = 0
                micDebugMaxRMS = 0
                micDebugMaxPeak = 0
            }
        }

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
                self.satellite.interruptPlayback()

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
                if Config.debugTurnRecording {
                    let url = URL(
                        fileURLWithPath:
                            Config.debugTurnRecordingPath
                            + "/atlas-turn-\(Int(Date().timeIntervalSince1970 * 1000)).wav"
                    )
                    try? writeWAV(
                        pcm: completedRecording,
                        sampleRate: Int(completedSampleRate),
                        to: url
                    )
                }
                await self.processTurn(
                    pcm: completedRecording,
                    sampleRate: completedSampleRate
                )
            }
        }
    }

    func handleSatelliteDisconnect() {
        var wasRecording = false

        lock.withLock {
            wasRecording = state == .recording
            state = .listening
            recording = Data()
            speechFrames = 0
            silenceFrames = 0
            clearPreRoll()
            queuedAudioBuffers = 0
            currentPlaybackPurpose = nil
        }

        if wasRecording {
            cancelRecognizerSession()
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
        _ samples: UnsafePointer<Float>,
        count: Int
    ) -> Float {
        var sum: Float = 0

        for index in 0..<count {
            sum += samples[index] * samples[index]
        }

        return sqrt(sum / Float(count))
    }

    func peak(
        _ samples: UnsafePointer<Float>,
        count: Int
    ) -> Float {
        var value: Float = 0

        for index in 0..<count {
            value = max(value, abs(samples[index]))
        }

        return value
    }

    func floatToPCM16(
        _ samples: UnsafePointer<Float>,
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
