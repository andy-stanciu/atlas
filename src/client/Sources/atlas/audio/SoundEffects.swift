import AVFoundation
import Foundation

final class SoundEffects {
    private let satellite: SatelliteLink
    private var cache: [String: Data] = [:]
    private let lock = NSLock()
    private var missing: Set<String> = []

    init(satellite: SatelliteLink) {
        self.satellite = satellite
        for name in [
            "startup", "shutdown", "tool_call", "reminder", "announcement",
        ] {
            if let pcm = decode(name, fileExtension: "mp3", volume: Config.sfxVolume) {
                cache["\(name).mp3"] = pcm
            } else {
                Log.system("[sound effect missing] \(name).mp3")
                missing.insert("\(name).mp3")
            }
        }
    }

    /// Plays a sound effect, decoding and caching it on first use.
    /// Tries "<name>.mp3" first, then "<name>.wav". Returns false if
    /// neither exists, so callers can fall back to a generic cue.
    @discardableResult
    func play(
        _ name: String,
        fileExtension: String = "mp3",
        volume: Float = Config.sfxVolume
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let pcm = cache["\(name).mp3"] ?? cache["\(name).wav"] {
            satellite.enqueue(pcm: pcm) { _ in }
            return true
        }
        let pcm =
            decode(name, fileExtension: fileExtension, volume: volume)
            ?? (fileExtension == "mp3"
                ? decode(name, fileExtension: "wav", volume: volume)
                : nil)

        guard let pcm else {
            if missing.insert("\(name).\(fileExtension)").inserted {
                Log.system("[sound effect missing] \(name)")
            }
            return false
        }
        cache["\(name).\(fileExtension)"] = pcm
        satellite.enqueue(pcm: pcm) { _ in }
        return true
    }

    private func decode(
        _ name: String,
        fileExtension: String,
        volume: Float
    ) -> Data? {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "sfx"
            ),
            let file = try? AVAudioFile(forReading: url)
        else {
            return nil
        }

        let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.satelliteDownlinkSampleRate,
            channels: 1,
            interleaved: false
        )!
        let sourceFrames = AVAudioFrameCount(file.length)

        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: sourceFrames
            ),
            let converter = AVAudioConverter(
                from: file.processingFormat,
                to: floatFormat
            )
        else {
            return nil
        }

        do {
            try file.read(into: sourceBuffer)
        } catch {
            return nil
        }

        let ratio = floatFormat.sampleRate / file.processingFormat.sampleRate
        let capacity =
            AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: floatFormat,
                frameCapacity: capacity
            )
        else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _,
            outputStatus in
            if consumed {
                outputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil,
            let floats = output.floatChannelData
        else {
            return nil
        }

        let count = Int(output.frameLength)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let scaled = max(
                -1,
                min(1, floats[0][index] * volume)
            )
            var value = Int16(scaled * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) {
                pcm.append(contentsOf: $0)
            }
        }
        return pcm
    }
}
