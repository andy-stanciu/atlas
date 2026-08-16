import Foundation
import OSLog
@preconcurrency import WhisperKit

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

/// Rolling on-device speech recognizer for Atlas. Accumulates a turn of
/// audio and transcribes it once, in full, at end-of-speech.
actor StreamingSpeechRecognizer {
    private let logger = Logger(
        subsystem: "Atlas",
        category: "StreamingSpeechRecognizer"
    )

    private let whisperKit: WhisperKit

    private var audioSamples: [Float] = []
    private var sessionActive = false
    private var cancelled = false
    private var finalizing = false

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    /// Creates a recognizer with a pre-loaded local model folder
    /// (e.g. the `large-v3-v20240930_626MB` folder already downloaded by
    /// argmax-cli). No download or remote config lookup is performed.
    init(modelFolder: String) async throws {
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

        self.init(whisperKit: whisperKit)
    }

    var isActive: Bool {
        sessionActive
    }

    func begin() {
        sessionActive = true
        cancelled = false
        finalizing = false
        audioSamples.removeAll(keepingCapacity: true)
    }

    /// Appends one chunk of microphone audio. Call with the same PCM16
    /// data Atlas already records, plus the audio's sample rate.
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

    /// Runs the full-buffer transcription and returns the text.
    func finish() async throws -> String {
        guard sessionActive else {
            return ""
        }

        finalizing = true

        defer {
            sessionActive = false
            finalizing = false
            audioSamples.removeAll(keepingCapacity: false)
        }

        if cancelled {
            throw StreamingSpeechRecognizerError.cancelled
        }

        guard !audioSamples.isEmpty else {
            return ""
        }

        do {
            let text = try await Self.runTranscription(
                whisperKit: whisperKit,
                samples: audioSamples,
                logger: logger
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
        audioSamples.removeAll(keepingCapacity: false)
    }

    func loadTimingsDescription() -> String {
        let t = whisperKit.currentTimings
        return """
            modelLoading=\(t.modelLoading)s \
            encoder=\(t.encoderLoadTime)s decoder=\(t.decoderLoadTime)s \
            tokenizer=\(t.tokenizerLoadTime)s prewarm=\(t.prewarmLoadTime)s
            """
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
