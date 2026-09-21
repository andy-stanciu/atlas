import Darwin
import Foundation

struct StereoResampler {
    let srcRate: Double
    let dstRate: Double
    private var phase: Double = 0
    private var history: [Int16]

    init(srcRate: Double, dstRate: Double) {
        self.srcRate = srcRate
        self.dstRate = dstRate
        history = [Int16](repeating: 0, count: 8)
    }

    mutating func process(_ input: [Int16]) -> [Int16] {
        var window = history
        window.append(contentsOf: input)
        let pairCount = window.count / 2
        var output: [Int16] = []
        output.reserveCapacity(Int(Double(input.count / 2) * dstRate / srcRate) + 8)

        while Double(floor(phase)) + 6 <= Double(pairCount - 1) {
            let base = Int(floor(phase))
            let t = Float(phase - Double(base))
            for channel in 0..<2 {
                let p0 = Float(window[2 * (base + 3) + channel])
                let p1 = Float(window[2 * (base + 4) + channel])
                let p2 = Float(window[2 * (base + 5) + channel])
                let p3 = Float(window[2 * (base + 6) + channel])
                let value =
                    0.5
                    * ((2 * p1) + (-p0 + p2) * t
                        + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                        + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
                output.append(Int16(max(-32768, min(32767, value.rounded()))))
            }
            phase += srcRate / dstRate
        }

        let consumedPairs = pairCount - 4
        if consumedPairs > 0 {
            phase -= Double(consumedPairs)
            window.removeFirst(consumedPairs * 2)
        }
        history = window
        return output
    }
}

final class MusicStream: @unchecked Sendable {
    private let satellite: SatelliteLink
    private var task: Task<Void, Never>?

    init(satellite: SatelliteLink) {
        self.satellite = satellite
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .userInitiated) { [satellite] in
            await MusicStream.run(satellite: satellite)
        }
    }

    private static func run(satellite: SatelliteLink) async {
        let path = Config.musicFIFOPath
        mkfifo(path, 0o644)

        while !Task.isCancelled {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            await stream(fd: fd, satellite: satellite)
            close(fd)
        }
    }

    private static func stream(fd: Int32, satellite: SatelliteLink) async {
        var resampler = StereoResampler(
            srcRate: Config.musicSourceSampleRate,
            dstRate: Config.musicDownlinkSampleRate
        )
        let frameBytes = Int(Config.musicDownlinkSampleRate / 50) * 4
        var pending = Data()
        var frame = Data()
        var nextAt: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 16384)
        var totalRead = 0
        var totalFrames = 0
        var lastLog = DispatchTime.now().uptimeNanoseconds

        while !Task.isCancelled {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs - lastLog > 5_000_000_000 {
                let elapsed = Double(nowNs - lastLog) / 1_000_000_000
                Log.music(
                    String(
                        format: "%d frames in %.1fs (%.0f fps), %.1f KB read",
                        totalFrames, elapsed, Double(totalFrames) / elapsed,
                        Double(totalRead) / 1024
                    ))
                totalRead = 0
                totalFrames = 0
                lastLog = nowNs
            }

            let count = read(fd, &buffer, buffer.count)
            if count == 0 {
                return
            }
            guard count > 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            totalRead += count
            pending.append(contentsOf: buffer[0..<count])

            while pending.count >= 4 {
                let usable = pending.count / 4 * 4
                var samples = [Int16](repeating: 0, count: usable / 2)
                _ = samples.withUnsafeMutableBytes { destination in
                    pending.withUnsafeBytes { source in
                        if let src = source.baseAddress,
                            let dst = destination.baseAddress
                        {
                            memcpy(dst, src, usable)
                        }
                    }
                }
                pending.removeFirst(usable)

                let output = resampler.process(samples)
                output.withUnsafeBytes { raw in
                    frame.append(contentsOf: raw)
                }

                while frame.count >= frameBytes {
                    let chunk = Data(frame.prefix(frameBytes))
                    frame.removeFirst(frameBytes)
                    nextAt = await pace(nextAt)
                    satellite.sendMusicFrame(chunk)
                    totalFrames += 1
                }
            }
        }
    }

    private static func pace(_ nextAt: UInt64) async -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        var deadline = nextAt
        if nextAt == 0 || nextAt + 100_000_000 < now {
            deadline = now
        }
        if deadline > now {
            try? await Task.sleep(nanoseconds: deadline - now)
        }
        return deadline + 20_000_000
    }
}
