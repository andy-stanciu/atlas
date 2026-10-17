import Foundation

extension VoiceAssistant {

    func updateSatelliteListening() {
        let on = lock.withLock { conversationActive || state != .listening }
        satellite?.setListening(on)
    }

    func armWake() {
        let started = lock.withLock { () -> Bool in
            guard state == .listening, !conversationActive else {
                return false
            }
            wakeLatched = true
            recording = Data()
            speechFrames = 0
            silenceFrames = 0
            processingTurnIsLive = false
            clearPreRoll()
            state = .recording
            return true
        }
        guard started else {
            satellite?.resync()
            return
        }
        Log.blank()
        Log.system("Wake word detected. Listening...", terminator: "")
        beginRecognizerSession(preRoll: Data())
    }

    func clearWakeLatch() {
        lock.withLock { wakeLatched = false }
    }

    func takeWakeLatch() -> Bool {
        lock.withLock {
            defer { wakeLatched = false }
            return wakeLatched
        }
    }

    func firstTurnText(_ transcript: String) -> String {
        let tokens = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let rest =
            tokens.firstIndex { Config.wakeWords.contains(normalizedText($0)) }
            .map { Array(tokens[($0 + 1)...]) } ?? tokens
        let tail = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? Config.wakeGreeting : "\(Config.wakeGreeting), \(tail)"
    }
}
