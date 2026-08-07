import AVFoundation
import Foundation
import QuartzCore

final class VoiceAssistant {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let lock = NSRecursiveLock()

    let ttsQueue = DispatchQueue(
        label: "atlas.tts",
        qos: .userInitiated
    )
    let lifecycleQueue = DispatchQueue(
        label: "atlas.lifecycle",
        qos: .userInitiated
    )

    let voiceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    let kokoro: KokoroWorker
    let ollama = OllamaClient()
    let toolServer = ToolServerClient()
    let speakerClient = SpeakerClient()
    let speakerEnrollment: SpeakerEnrollmentCoordinator
    let consoleTranscript = ConsoleTranscript()
    var sttClient: STTClient?
    var recognizerFeedChain: Task<Void, Never> = Task {}
    var sttConnectTask: Task<Void, Never> = Task {}

    var playback: AudioPlayback!
    var notificationCoordinator: NotificationCoordinator?

    var state: AssistantState = .listening
    var recording = Data()
    var recordingSampleRate: Double = 48_000
    let soundEffects = SoundEffects()

    var preRollBuffers = [Data]()
    var preRollBytes = 0

    var speechFrames = 0
    var silenceFrames = 0
    var queuedAudioBuffers = 0
    var speakingStartedAt: CFTimeInterval = 0

    var conversationActive = false
    var conversationTimeoutWorkItem: DispatchWorkItem?
    var shouldEndConversationAfterSpeech = false

    var activeTurnID: UUID?
    var activeTurnText: String?
    var activeTurnSpeaker: SpeakerIdentity?
    var generationTask: Task<Void, Never>?
    var currentPlaybackPurpose: PlaybackPurpose?
    var pendingMergedText: String?
    var lastThinkingFiller: String?

    var history = [
        Message(role: "system", content: SystemPrompts.mainSystemPrompt)
    ]

    init() throws {
        kokoro = try KokoroWorker()
        speakerEnrollment = SpeakerEnrollmentCoordinator(
            speakerClient: speakerClient,
            ollama: ollama
        )

        playback = AudioPlayback(
            player: player,
            kokoro: kokoro,
            queue: ttsQueue,
            voiceFormat: voiceFormat,
            beginSpeaking: { [weak self] purpose in
                self?.beginPlayback(purpose: purpose) ?? false
            },
            finishSpeaking: { [weak self] purpose in
                self?.bufferFinished(purpose: purpose)
            },
            beginScheduledSpeech: { [weak self] in
                self?.beginScheduledSpeech() ?? false
            },
        )

        let lock = self.lock
        sttConnectTask = Task { [weak self] in
            let client = STTClient()
            do {
                try await client.connect()
                await client.setPartialTextHandler { [weak self] text in
                    self?.handleLiveTranscript(text)
                }
                lock.withLock {
                    self?.sttClient = client
                }
                print("[stt] Connected to sttd.")
            } catch {
                fatalError(
                    "Could not connect to sttd — start it with "
                        + "'swift run sttd <model-folder>' in another terminal: "
                        + error.localizedDescription
                )
            }
        }
    }

    deinit {
        notificationCoordinator = nil
    }

    func start() async throws {
        print("Connecting to speech recognition daemon...")
        await sttConnectTask.value

        try configureAudioEngine()
        startNotificationCoordinator()

        print(
            """
            Voice-processing audio engine started.
            Say “Hey Atlas” or “Hi Atlas” to begin. Press Ctrl-C to quit.

            """
        )
    }

    internal func isCurrentTurn(_ turnID: UUID) -> Bool {
        lock.withLock {
            activeTurnID == turnID
        }
    }
}
