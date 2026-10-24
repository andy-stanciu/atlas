import Foundation

extension VoiceAssistant {
    var shouldDuckMusic: Bool {
        lock.withLock { state != .listening || conversationActive || wakeLatched }
    }

    func updateMusicDuck() {
        let ducked = shouldDuckMusic
        satellite.sendMusicDuck(
            gain: ducked ? Config.musicDuckGain : Config.musicMaxVolume,
            cutoffHz: ducked ? Config.musicDuckLowPassHz : Config.musicOpenLowPassHz
        )
    }
}
