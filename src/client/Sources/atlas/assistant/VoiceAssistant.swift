import AVFoundation
import Foundation
import QuartzCore

final class VoiceAssistant {
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
        sampleRate: Config.satelliteDownlinkSampleRate,
        channels: 1,
        interleaved: false
    )!

    let kokoro: KokoroWorker
    let ollama = OllamaClient()
    let toolServer = ToolServerClient()
    let speakerClient = SpeakerClient()
    let speakerEnrollment: SpeakerEnrollmentCoordinator
    var sttClient: STTClient?
    var recognizerFeedChain: Task<Void, Never> = Task {}
    var sttConnectTask: Task<Void, Never> = Task {}

    var satellite: SatelliteLink!
    var soundEffects: SoundEffects!
    var playback: AudioPlayback!
    var notificationCoordinator: NotificationCoordinator?

    var state: AssistantState = .listening {
        didSet {
            updateLEDState()
        }
    }
    var recording = Data()
    var recordingSampleRate: Double = 16_000

    var preRollBuffers = [Data]()
    var preRollBytes = 0

    var speechFrames = 0
    var silenceFrames = 0
    var queuedAudioBuffers = 0
    var speakingStartedAt: CFTimeInterval = 0

    // Debug metering; only touched on the satellite audio queue
    var micDebugFrames = 0
    var micDebugMaxRMS: Float = 0
    var micDebugMaxPeak: Float = 0

    var conversationActive = false {
        didSet {
            updateLEDState()
        }
    }
    var conversationTimeoutWorkItem: DispatchWorkItem?
    var shouldEndConversationAfterSpeech = false

    var activeTurnID: UUID?
    var activeTurnText: String?
    var activeTurnSpeaker: SpeakerIdentity?
    var generationTask: Task<Void, Never>?
    var currentPlaybackPurpose: PlaybackPurpose? {
        didSet {
            updateLEDState()
        }
    }
    var processingTurnIsLive = false {
        didSet {
            updateLEDState()
        }
    }
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

        satellite = SatelliteLink(
            port: UInt16(Config.satellitePort),
            onAudio: { [weak self] samples, count in
                self?.handleAudio(samples: samples, count: count)
            },
            onDisconnect: { [weak self] in
                self?.handleSatelliteDisconnect()
            }
        )
        soundEffects = SoundEffects(satellite: satellite)

        playback = AudioPlayback(
            satellite: satellite,
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
                lock.withLock {
                    self?.sttClient = client
                }
                Log.system("Connected to sttd.")
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
        Log.system("Connecting to speech recognition daemon...")
        await sttConnectTask.value

        try satellite.start()
        startNotificationCoordinator()

        Log.system(
            """
            Satellite listener started on port \(Config.satellitePort).
            Waiting for the satellite to connect...
            """
        )
    }

    internal func isCurrentTurn(_ turnID: UUID) -> Bool {
        lock.withLock {
            activeTurnID == turnID
        }
    }

    func updateLEDState() {
        let ledState: SatelliteLEDState = lock.withLock {
            switch state {
            case .listening:
                return conversationActive ? .conversationOpen : .idle
            case .recording:
                return .recording
            case .processing:
                return processingTurnIsLive ? .processing : .idle
            case .speaking:
                return currentPlaybackPurpose == .thinkingFiller
                    ? .processing
                    : .speaking
            }
        }
        satellite?.setLEDState(ledState)
    }
}
