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

    let kokoro: KokoroWorker
    let llm = LLMClient()
    let toolServer = ToolServerClient()
    let speakerClient = SpeakerClient()
    let speakerEnrollment: SpeakerEnrollmentCoordinator
    var sttClient: STTClient?
    var recognizerFeedChain: Task<Void, Never> = Task {}
    var sttHealthCheckTask: Task<Void, Never> = Task {}
    var currentPauseScore: Double = 0

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
    var cachedTools: [ToolDefinition]?

    init() throws {
        kokoro = KokoroWorker()
        speakerEnrollment = SpeakerEnrollmentCoordinator(
            speakerClient: speakerClient,
            llm: llm
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
        sttClient = STTClient(
            onPauseScoreUpdate: { [weak self] score in
                lock.withLock { self?.currentPauseScore = score }
            },
            onWordReceived: { [weak self] in
                self?.handleWordReceived()
            }
        )

        sttHealthCheckTask = Task { [weak self] in
            guard let client = self?.sttClient else { return }
            do {
                try await client.verifyReachable()
                Log.system("Atlas STT server is reachable.")
            } catch {
                fatalError(
                    "Could not reach the Atlas STT server — make sure the "
                        + "'atlas-stt' systemd service is running on the desktop: "
                        + error.localizedDescription
                )
            }
        }
    }

    deinit {
        notificationCoordinator = nil
    }

    func start() async throws {
        Log.system("Checking connectivity to the Atlas STT server...")
        await sttHealthCheckTask.value

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
