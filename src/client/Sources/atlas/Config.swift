import Foundation

struct Config {
    static let whisperKitModelFolder =
        "\(NSHomeDirectory())/workplace/atlas/argmax-oss-swift/Models/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB"

    static let ollamaURL = URL(
        string: "http://127.0.0.1:11434/api/chat"
    )!

    static let toolServerURL = URL(
        string: "http://127.0.0.1:8090"
    )!

    static let toolServerTimeout: TimeInterval = 5
    static let speakerIdentificationTimeout: TimeInterval = 2
    static let speechPollIntervalSeconds: TimeInterval = 2
    static let reminderRepeatIntervalSeconds: TimeInterval = 30
    static let reminderMaxAnnouncements = 20
    static let ollamaContextWindow = 8192
    static let ollamaDefaultTemperature = 0.2

    static let ollamaModel = "qwen3.5:9b"
    static let maxToolLoopSteps = 10

    static let pythonExecutable =
        ProcessInfo.processInfo.environment["PYTHON_EXECUTABLE"]
        ?? "\(NSHomeDirectory())/workplace/atlas/src/client/.venv/bin/python"

    static let ttsWorkerScript =
        "\(NSHomeDirectory())/workplace/atlas/src/client/kokoro_worker.py"

    static let speechThreshold: Float = 0.025
    static let speechPeakThreshold: Float = 0.055

    static let startSpeechFrames = 2
    static let interruptSpeechFrames = 4
    static let endSilenceFrames = 20
    static let minimumRecordingBytes = 2_000
    static let preRollMilliseconds = 500

    static let conversationTimeoutSeconds: TimeInterval = 10
    static let interruptGracePeriodSeconds: CFTimeInterval = 2.0

    static let speakerReinforceThreshold = 0.60
    static let speakerReinforceMinimumDurationSeconds = 4.0
    static let speakerEnrollmentMinimumClipSeconds = 4.0

    static let wakeGreetings = [
        "hey",
        "hi",
        "hello",
        "good morning",
        "good afternoon",
        "good evening",
    ]

    static let maxHistoryMessages = 10

    static let thinkingFillers = [
        "One second, please.",
        "One moment, please.",
        "Let me think.",
        "I'm thinking, one second.",
        "I'm thinking, one moment.",
        "Give me a moment.",
        "Give me a second.",
        "One second.",
        "One moment.",
        "Just a moment.",
        "Just a second.",
        "Just a moment, please.",
        "Give me a second.",
    ]

    static let sfxVolume: Float = 0.7
    static let speakingVolume: Float = 0.9
    static let toolCueFrequency1: Double = 880
    static let toolCueFrequency2: Double = 1_320
    static let toolCueDuration: TimeInterval = 0.14
}
