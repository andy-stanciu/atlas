import Foundation

extension VoiceAssistant {
    func updateMusicDuck() {
        let ducked = lock.withLock {
            state == .speaking
                || (conversationActive && state == .recording)
        }
        satellite.sendMusicDuck(
            gain: ducked ? Config.musicDuckGain : Config.musicMaxVolume,
            cutoffHz: ducked ? Config.musicDuckLowPassHz : Config.musicOpenLowPassHz
        )
    }
}
