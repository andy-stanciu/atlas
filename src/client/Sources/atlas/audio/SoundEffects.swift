import AVFoundation
import Foundation

final class SoundEffects {
    private let queue = DispatchQueue(
        label: "atlas.sound-effects",
        qos: .userInitiated
    )

    private var players: [String: AVAudioPlayer] = [:]

    func play(_ name: String, fileExtension: String = "mp3") {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                guard
                    let url = Bundle.module.url(
                        forResource: name,
                        withExtension: fileExtension,
                        subdirectory: "sfx"
                    )
                else {
                    print("[sound effect missing] \(name).\(fileExtension)")
                    return
                }

                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = Config.sfxVolume
                player.prepareToPlay()
                player.play()

                self.players[name] = player
            } catch {
                print("[sound effect error] \(name): \(error.localizedDescription)")
            }
        }
    }
}
