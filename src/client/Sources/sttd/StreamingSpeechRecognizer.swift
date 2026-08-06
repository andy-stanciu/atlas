import Foundation
import OSLog
@preconcurrency import WhisperKit

struct StreamingTranscriptUpdate: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}

enum StreamingSpeechRecognizerError: LocalizedError {
    case cancelled
    case emptyAudio
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Streaming speech recognition was cancelled."
        case .emptyAudio:
            return "No audio was captured for streaming speech recognition."
        case .transcriptionFailed(let message):
            return "Streaming speech recognition failed: \(message)"
        }
    }
}

/// Converts little-endian PCM16 data to Float32 samples in [-1, 1].
func pcm16ToFloat(_ data: Data) -> [Float] {
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else {
            return []
        }

        let count = rawBuffer.count / MemoryLayout<Int16>.size
        let samples = base.assumingMemoryBound(to: Int16.self)

        var floats = [Float]()
        floats.reserveCapacity(count)

        for index in 0..<count {
            floats.append(
                Float(Int16(littleEndian: samples[index]))
                    / Float(Int16.max)
            )
        }

        return floats
    }
}

/// Linear-interpolation resampler. Adequate for 48 kHz -> 16 kHz speech.
func resampleTo16kHz(
    _ samples: [Float],
    sourceSampleRate: Int
) -> [Float] {
    let targetRate = WhisperKit.sampleRate

    guard sourceSampleRate > 0,
        sourceSampleRate != targetRate,
        !samples.isEmpty
    else {
        return samples
    }

    let ratio = Double(sourceSampleRate) / Double(targetRate)
    let targetCount = Int(Double(samples.count) / ratio)

    guard targetCount > 0 else {
        return []
    }

    var output = [Float]()
    output.reserveCapacity(targetCount)

    for index in 0..<targetCount {
        let position = Double(index) * ratio
        let lower = Int(position)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = Float(position - Double(lower))

        output.append(
            samples[lower] * (1 - fraction)
                + samples[upper] * fraction
        )
    }

    return output
}

/// Rolling on-device speech recognizer for Atlas.
///
/// Design notes:
/// - Does NOT use `AudioStreamTranscriber`; that type owns microphone
///   capture and would conflict with Atlas's existing AVAudioEngine tap.
/// - Follows the CLI's simulated-streaming pattern: repeatedly transcribe
///   the full accumulated buffer while recording, then run one final pass
///   at end-of-speech. Voice-assistant turns are short (typically < 15 s),
///   so full-buffer retranscription is cheap enough and avoids any risk of
///   dropping audio with seek heuristics.
/// - The update loop self-throttles: a new partial pass is only started
///   once wall-clock time exceeds the duration of the previous pass, so a
///   slow device simply produces fewer partials.
actor StreamingSpeechRecognizer {
    private let logger = Logger(
        subsystem: "Atlas",
        category: "StreamingSpeechRecognizer"
    )

    private let whisperKit: WhisperKit
    private let partialUpdate: (@Sendable (StreamingTranscriptUpdate) -> Void)?
    private let updateIntervalSeconds: Double
    private let minimumPartialSamples: Int

    private var audioSamples: [Float] = []
    private var updateTask: Task<Void, Never>?
    private var currentTranscribeTask: Task<String, Error>?
    private var lastPassStartedAt = Date.distantPast
    private var lastPassDuration: TimeInterval = 0
    private var lastPassSampleCount = 0
    private var latestText = ""
    private var latestError: Error?
    private var sessionActive = false
    private var cancelled = false
    private var finalizing = false

    init(
        whisperKit: WhisperKit,
        partialUpdate: (@Sendable (StreamingTranscriptUpdate) -> Void)? = nil,
        updateIntervalSeconds: Double = 0.4,
        minimumPartialSeconds: Double = 1.0
    ) {
        self.whisperKit = whisperKit
        self.partialUpdate = partialUpdate
        self.updateIntervalSeconds = updateIntervalSeconds
        self.minimumPartialSamples = Int(
            minimumPartialSeconds * Double(WhisperKit.sampleRate)
        )
    }

    /// Creates a recognizer with a pre-loaded local model folder
    /// (e.g. the `large-v3-v20240930_626MB` folder already downloaded by
    /// argmax-cli). No download or remote config lookup is performed.
    init(
        modelFolder: String,
        partialUpdate: (@Sendable (StreamingTranscriptUpdate) -> Void)? = nil
    ) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false,
            useBackgroundDownloadSession: false
        )

        let whisperKit = try await WhisperKit(config)

        self.init(
            whisperKit: whisperKit,
            partialUpdate: partialUpdate
        )
    }

    var isActive: Bool {
        sessionActive
    }

    func begin() {
        currentTranscribeTask?.cancel()
        currentTranscribeTask = nil
        updateTask?.cancel()
        updateTask = nil

        sessionActive = true
        cancelled = false
        finalizing = false
        audioSamples.removeAll(keepingCapacity: true)
        latestText = ""
        latestError = nil
        lastPassStartedAt = .distantPast
        lastPassDuration = 0
        lastPassSampleCount = 0

        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                try? await Task.sleep(
                    nanoseconds: UInt64(self.updateIntervalSeconds * 1_000_000_000)
                )

                guard !Task.isCancelled else {
                    return
                }

                await self.transcribePartialIfDue()
            }
        }
    }

    /// Appends one chunk of microphone audio. Call with the same PCM16
    /// data Atlas already records, plus the engine's sample rate.
    func appendPCM16(_ pcm: Data, sourceSampleRate: Int) {
        guard sessionActive, !finalizing, !cancelled else {
            return
        }

        let floats = pcm16ToFloat(pcm)
        let resampled = resampleTo16kHz(
            floats,
            sourceSampleRate: sourceSampleRate
        )

        audioSamples.append(contentsOf: resampled)
    }

    /// Runs one final full-buffer transcription and returns the text.
    /// Throws on cancellation or failure so callers can fall back to the
    /// server-side Whisper path.
    func finish() async throws -> String {
        guard sessionActive else {
            return latestText
        }

        finalizing = true
        updateTask?.cancel()
        updateTask = nil

        // Let any in-flight partial pass finish, then do the final pass.
        if let inFlight = currentTranscribeTask {
            _ = try? await inFlight.value
            currentTranscribeTask = nil
        }

        defer {
            sessionActive = false
            finalizing = false
            audioSamples.removeAll(keepingCapacity: false)
            latestText = ""
            latestError = nil
        }

        if cancelled {
            throw StreamingSpeechRecognizerError.cancelled
        }

        guard !audioSamples.isEmpty else {
            return ""
        }

        do {
            let text = try await transcribe(
                samples: audioSamples,
                isFinal: true
            )

            if cancelled {
                throw StreamingSpeechRecognizerError.cancelled
            }

            // Empty text is a normal "no speech detected" outcome, not a
            // failure — let callers treat it the same as any other transcript.
            return text
        } catch let error as StreamingSpeechRecognizerError {
            throw error
        } catch is CancellationError {
            throw StreamingSpeechRecognizerError.cancelled
        } catch {
            throw StreamingSpeechRecognizerError.transcriptionFailed(
                error.localizedDescription
            )
        }
    }

    func cancel() {
        cancelled = true
        sessionActive = false
        finalizing = false
        updateTask?.cancel()
        updateTask = nil
        currentTranscribeTask?.cancel()
        currentTranscribeTask = nil
        audioSamples.removeAll(keepingCapacity: false)
        latestText = ""
        latestError = nil
    }

    /// Latest partial transcript, for wake-gating or display.
    func currentTranscript() -> String {
        latestText
    }

    func loadTimingsDescription() -> String {
        let t = whisperKit.currentTimings
        return """
            modelLoading=\(t.modelLoading)s \
            encoder=\(t.encoderLoadTime)s decoder=\(t.decoderLoadTime)s \
            tokenizer=\(t.tokenizerLoadTime)s prewarm=\(t.prewarmLoadTime)s
            """
    }

    // MARK: - Private

    private func transcribePartialIfDue() async {
        guard sessionActive, !finalizing, !cancelled else {
            return
        }

        guard currentTranscribeTask == nil else {
            return
        }

        guard audioSamples.count >= minimumPartialSamples else {
            return
        }

        // Don't start a new pass if we have no new audio since the last one.
        guard audioSamples.count > lastPassSampleCount else {
            return
        }

        // Adaptive throttle: only start a new pass once wall time has
        // caught up with the previous pass duration.
        guard
            Date().timeIntervalSince(lastPassStartedAt) >= lastPassDuration
        else {
            return
        }

        lastPassStartedAt = Date()
        lastPassSampleCount = audioSamples.count

        let snapshot = audioSamples

        let task = Task<String, Error> { [whisperKit, logger] in
            try await Self.runTranscription(
                whisperKit: whisperKit,
                samples: snapshot,
                logger: logger
            )
        }

        currentTranscribeTask = task

        do {
            let text = try await task.value

            guard !cancelled, sessionActive else {
                return
            }

            lastPassDuration = Date().timeIntervalSince(lastPassStartedAt)
            latestText = text
            partialUpdate?(
                StreamingTranscriptUpdate(text: text, isFinal: false)
            )
        } catch {
            guard !cancelled, sessionActive else {
                return
            }

            lastPassDuration = Date().timeIntervalSince(lastPassStartedAt)
            latestError = error
            logger.error(
                "Partial transcription failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        currentTranscribeTask = nil
    }

    private func transcribe(
        samples: [Float],
        isFinal: Bool
    ) async throws -> String {
        let text = try await Self.runTranscription(
            whisperKit: whisperKit,
            samples: samples,
            logger: logger
        )

        if isFinal {
            partialUpdate?(
                StreamingTranscriptUpdate(text: text, isFinal: true)
            )
        }

        return text
    }

    private static func runTranscription(
        whisperKit: WhisperKit,
        samples: [Float],
        logger: Logger
    ) async throws -> String {
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1,
            chunkingStrategy: .vad
        )

        let startedAt = Date()

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        try Task.checkCancellation()

        let text =
            results
            .map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let elapsed = Date().timeIntervalSince(startedAt)
        let audioSeconds =
            Double(samples.count)
            / Double(WhisperKit.sampleRate)

        logger.debug(
            "Transcribed \(audioSeconds, privacy: .public)s of audio in \(elapsed, privacy: .public)s"
        )

        return text
    }
}
