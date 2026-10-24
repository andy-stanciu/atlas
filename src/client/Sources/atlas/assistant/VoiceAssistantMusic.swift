import Foundation

extension VoiceAssistant {
    var turnInProgress: Bool {
        lock.withLock { state != .listening || wakeLatched }
    }

    func sendMusicDuck(_ ducked: Bool) {
        satellite.sendMusicDuck(
            gain: ducked ? Config.musicDuckGain : Config.musicMaxVolume,
            cutoffHz: ducked ? Config.musicDuckLowPassHz : Config.musicOpenLowPassHz
        )
    }

    func updateMusicDuck() {
        lock.withLock {
            if turnInProgress {
                musicReleaseWorkItem?.cancel()
                musicReleaseWorkItem = nil
                sendMusicDuck(true)
                return
            }
            guard musicReleaseWorkItem == nil else { return }
            let release = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.musicReleaseWorkItem = nil
                    if !self.turnInProgress { self.sendMusicDuck(false) }
                }
            }
            musicReleaseWorkItem = release
            lifecycleQueue.asyncAfter(
                deadline: .now() + Config.musicDuckHoldSeconds, execute: release)
        }
    }
}
