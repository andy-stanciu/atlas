import Accelerate
import Darwin
import Dispatch
import Foundation
import QuartzCore

enum SatelliteLEDState: UInt8 {
    case idle = 0
    case recording = 1
    case processing = 2
    case speaking = 3
    case conversationOpen = 4
}

final class DebugMicTap {
    private let path: String
    private let maxBytes: Int
    private var pcm = Data()
    private var lastWrite = Date.distantPast

    init(path: String, maxSeconds: Int) {
        self.path = path
        maxBytes = maxSeconds * 16_000 * 2
    }

    func append(_ data: Data) {
        pcm.append(data)
        if pcm.count > maxBytes {
            pcm = Data(pcm.suffix(maxBytes))
        }
        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= 5 else {
            return
        }
        lastWrite = now
        try? writeWAV(
            pcm: pcm,
            sampleRate: 16_000,
            to: URL(fileURLWithPath: path)
        )
    }
}

enum SatelliteLinkError: Error, CustomStringConvertible {
    case setupFailed(String)

    var description: String {
        switch self {
        case .setupFailed(let reason):
            return "Satellite link setup failed: \(reason)"
        }
    }
}

final class SatelliteLink: @unchecked Sendable {
    private enum FrameType: UInt8 {
        case mic = 0x01
        case tts = 0x02
        case control = 0x03
        case event = 0x04
        case music = 0x05
    }

    private enum Control: UInt8 {
        case flush = 0x01
        case ttsStart = 0x02
        case setState = 0x03
        case musicStop = 0x04
        case musicDuck = 0x05
    }

    private struct Burst {
        let pcm: Data
        let completion: (Bool) -> Void
    }

    private typealias Link = (fd: Int32, id: UInt64)

    private let port: UInt16
    private let onAudio: (UnsafePointer<Float>, Int) -> Void
    private let onDisconnect: () -> Void

    private let queue = DispatchQueue(
        label: "atlas.satellite",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "atlas.satellite.audio",
        qos: .userInitiated
    )

    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var linkID: UInt64 = 0

    private var listenFd: Int32 = -1
    private var rxBuffer = Data()

    private var pendingBursts: [Burst] = []
    private var generation = 0
    private var senderActive = false

    private var debugMicTap: DebugMicTap?
    private var loggedFirstFrame = false
    private var lastLEDState: SatelliteLEDState = .idle

    // Downlink debugging (queue-confined)
    private var burstSentFrames = 0
    private var burstTotalFrames = 0
    private var burstStart = DispatchTime.now()

    // 20 ms frames at the downlink wire rate (24 kHz s16le mono = 960 B)
    private let frameBytes =
        Int(Config.satelliteDownlinkSampleRate) / 50 * 2
    private let drainMargin = DispatchTimeInterval.milliseconds(150)

    init(
        port: UInt16,
        onAudio: @escaping (UnsafePointer<Float>, Int) -> Void,
        onDisconnect: @escaping () -> Void
    ) {
        self.port = port
        self.onAudio = onAudio
        self.onDisconnect = onDisconnect
    }

    func start() throws {
        if Config.debugMicRecording {
            debugMicTap = DebugMicTap(
                path: Config.debugMicRecordingPath,
                maxSeconds: Config.debugMicRecordingSeconds
            )
        }

        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else {
            throw SatelliteLinkError.setupFailed("socket() failed")
        }
        var one: Int32 = 1
        setsockopt(
            server,
            SOL_SOCKET,
            SO_REUSEADDR,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw SatelliteLinkError.setupFailed("bind() failed")
        }
        guard listen(server, 1) == 0 else {
            throw SatelliteLinkError.setupFailed("listen() failed")
        }
        listenFd = server

        let acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread.name = "atlas.satellite.accept"
        acceptThread.start()
    }

    // MARK: - Public send surface

    func enqueue(pcm: Data, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.currentLink().fd >= 0 else {
                Log.system("Satellite not connected; dropping audio.")
                completion(false)
                return
            }
            self.pendingBursts.append(Burst(pcm: pcm, completion: completion))
            if !self.senderActive {
                self.senderActive = true
                self.runSender()
            }
        }
    }

    func interruptPlayback() {
        queue.async {
            self.dropPending()
            self.sendControl(.flush)
        }
    }

    func setLEDState(_ state: SatelliteLEDState) {
        queue.async {
            guard state != self.lastLEDState else {
                return
            }
            self.lastLEDState = state
            self.sendLEDState(state)
        }
    }

    func sendMusicFrame(_ pcm: Data) {
        queue.async {
            self.sendFrame(.music, pcm)
        }
    }

    func sendMusicDuck(gain: Float) {
        let scaled = UInt8(max(0, min(1, gain)) * 255)
        queue.async {
            self.sendFrame(.control, Data([Control.musicDuck.rawValue, scaled]))
        }
    }

    func stopMusic() {
        queue.async {
            self.sendControl(.musicStop)
        }
    }

    // MARK: - Connection lifecycle

    private func acceptLoop() {
        while true {
            let client = accept(listenFd, nil, nil)
            guard client >= 0 else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            var one: Int32 = 1
            setsockopt(
                client,
                Int32(IPPROTO_TCP),
                TCP_NODELAY,
                &one,
                socklen_t(MemoryLayout<Int32>.size)
            )
            setsockopt(
                client,
                SOL_SOCKET,
                SO_KEEPALIVE,
                &one,
                socklen_t(MemoryLayout<Int32>.size)
            )
            var idle: Int32 = 5
            setsockopt(
                client, Int32(IPPROTO_TCP), TCP_KEEPALIVE, &idle,
                socklen_t(MemoryLayout<Int32>.size))
            var interval: Int32 = 3
            setsockopt(
                client, Int32(IPPROTO_TCP), TCP_KEEPINTVL, &interval,
                socklen_t(MemoryLayout<Int32>.size))
            var count: Int32 = 3
            setsockopt(
                client, Int32(IPPROTO_TCP), TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size)
            )

            // Non-blocking with poll-based reads so a superseded connection
            // can be closed without stranding a blocked reader thread.
            fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_NONBLOCK)

            queue.async { self.adoptClient(client) }
        }
    }

    private func adoptClient(_ client: Int32) {
        let previous = currentLink()
        if previous.fd >= 0 {
            close(previous.fd)
        }

        stateLock.lock()
        fd = client
        linkID += 1
        let id = linkID
        stateLock.unlock()

        rxBuffer = Data()
        Log.system("Satellite connected.")
        sendLEDState(lastLEDState)

        let link: Link = (client, id)
        Thread.detachNewThread { [weak self] in
            self?.readLoop(link)
        }
    }

    private func readLoop(_ link: Link) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var pfd = pollfd(fd: link.fd, events: Int16(POLLIN), revents: 0)

        while true {
            let ready = poll(&pfd, 1, 250)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if ready == 0 {
                if currentLink().id != link.id {
                    break
                }
                continue
            }
            if pfd.revents & Int16(POLLNVAL) != 0 || pfd.revents & Int16(POLLERR) != 0 {
                break
            }

            let n = read(link.fd, &buffer, buffer.count)
            if n == 0 {
                break
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                break
            }

            let chunk = Data(buffer[0..<n])
            queue.async { [weak self] in
                self?.ingest(chunk, linkID: link.id)
            }
        }

        queue.async { [weak self] in
            self?.readerExited(link)
        }
    }

    private func readerExited(_ link: Link) {
        guard currentLink().id == link.id else {
            return
        }
        stateLock.lock()
        if fd == link.fd {
            close(fd)
            fd = -1
        }
        stateLock.unlock()

        dropPending()
        Log.system("Satellite disconnected.")
        onDisconnect()
    }

    // MARK: - Receive path (queue-confined)

    private func ingest(_ data: Data, linkID: UInt64) {
        guard currentLink().id == linkID else {
            return
        }
        rxBuffer.append(data)
        parseFrames()
    }

    private func parseFrames() {
        // Data.removeFirst advances startIndex (it behaves like a view),
        // so all indexing here is relative to startIndex, never 0.
        while rxBuffer.count >= 5 {
            let s = rxBuffer.startIndex
            let len =
                Int(rxBuffer[s])
                | Int(rxBuffer[s + 1]) << 8
                | Int(rxBuffer[s + 2]) << 16
                | Int(rxBuffer[s + 3]) << 24
            let type = rxBuffer[s + 4]
            guard len <= 65_536 else {
                rxBuffer.removeFirst()
                continue
            }
            guard rxBuffer.count >= 5 + len else {
                return
            }
            let payload = rxBuffer.subdata(in: (s + 5)..<(s + 5 + len))
            rxBuffer.removeFirst(5 + len)
            handleFrame(type: type, payload: payload)
        }
    }

    private func handleFrame(type: UInt8, payload: Data) {
        guard type == FrameType.mic.rawValue else {
            return
        }
        let count = payload.count / 2
        guard count > 0 else {
            return
        }

        if !loggedFirstFrame {
            loggedFirstFrame = true
            Log.system("Mic streaming audio frames...")
        }
        debugMicTap?.append(payload)

        var floats = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else {
                return
            }
            vDSP_vflt16(src, 1, &floats, 1, vDSP_Length(count))
        }
        var scale: Float = 1.0 / 32_768.0
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))

        audioQueue.async { [weak self] in
            guard let self else {
                return
            }
            floats.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    return
                }
                self.onAudio(base, count)
            }
        }
    }

    // MARK: - Send path (queue-confined)

    private func currentLink() -> Link {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (fd, linkID)
    }

    private func sendLEDState(_ state: SatelliteLEDState) {
        sendFrame(.control, Data([Control.setState.rawValue, state.rawValue]))
    }

    private func sendControl(_ control: Control) {
        sendFrame(.control, Data([control.rawValue]))
    }

    private func sendFrame(_ type: FrameType, _ payload: Data) {
        let link = currentLink()
        guard link.fd >= 0 else {
            return
        }

        let len = UInt32(payload.count)
        var frame = Data(capacity: 5 + payload.count)
        frame.append(UInt8(len & 0xff))
        frame.append(UInt8((len >> 8) & 0xff))
        frame.append(UInt8((len >> 16) & 0xff))
        frame.append(UInt8((len >> 24) & 0xff))
        frame.append(type.rawValue)
        frame.append(payload)

        if !writeAll(link, frame) {
            handleWriteFailure(link)
        }
    }

    private func writeAll(_ link: Link, _ frame: Data) -> Bool {
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return false
            }
            var offset = 0
            while offset < frame.count {
                let n = write(link.fd, base + offset, frame.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN {
                    var pfd = pollfd(fd: link.fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 100) <= 0 {
                        return false
                    }
                    continue
                }
                return false
            }
            return true
        }
    }

    private func handleWriteFailure(_ link: Link) {
        guard currentLink().id == link.id else {
            return
        }
        stateLock.lock()
        if fd == link.fd {
            close(fd)
            fd = -1
        }
        stateLock.unlock()

        dropPending()
        Log.system("Satellite write failed; connection dropped.")
        onDisconnect()
    }

    // MARK: - TTS burst sender (queue-confined)

    private func runSender() {
        guard !pendingBursts.isEmpty else {
            senderActive = false
            return
        }
        let burst = pendingBursts.removeFirst()
        let gen = generation
        guard currentLink().fd >= 0 else {
            burst.completion(false)
            runSender()
            return
        }
        if Config.debugDownlinkStats {
            burstSentFrames = 0
            burstTotalFrames = (burst.pcm.count + frameBytes - 1) / frameBytes
            burstStart = .now()
            Log.system(
                "tts burst start: \(burst.pcm.count) B, "
                    + "\(burstTotalFrames) frames"
            )
        }
        sendControl(.ttsStart)
        sendBurstFrames(burst, frameIndex: 0, gen: gen, start: .now())
    }

    private func sendBurstFrames(
        _ burst: Burst,
        frameIndex: Int,
        gen: Int,
        start: DispatchTime
    ) {
        guard gen == generation, currentLink().fd >= 0 else {
            burst.completion(false)
            runSender()
            return
        }
        let offset = frameIndex * frameBytes
        if offset >= burst.pcm.count {
            // Fire the completion after the device drains its ring, but start
            // the next burst immediately — holding the margin here starved
            // the device's 100 ms ring at every sentence boundary.
            let sentFrames = burstSentFrames
            let startedAt = burstStart
            let pcmCount = burst.pcm.count
            queue.asyncAfter(deadline: .now() + drainMargin) { [weak self] in
                guard let self else {
                    return
                }
                if Config.debugDownlinkStats {
                    let elapsed =
                        Double(
                            DispatchTime.now().uptimeNanoseconds
                                - startedAt.uptimeNanoseconds
                        ) / 1_000_000_000
                    let audioSeconds =
                        Double(pcmCount) / 2
                        / Config.satelliteDownlinkSampleRate
                    Log.system(
                        String(
                            format: "tts burst done: %d frames in %.2fs "
                                + "(audio %.2fs)",
                            sentFrames,
                            elapsed,
                            audioSeconds
                        )
                    )
                }
                burst.completion(gen == self.generation)
            }
            runSender()
            return
        }
        let end = min(offset + frameBytes, burst.pcm.count)
        sendFrame(.tts, burst.pcm.subdata(in: offset..<end))

        if Config.debugDownlinkStats {
            burstSentFrames += 1
            if burstSentFrames % 100 == 0 {
                let elapsed =
                    Double(
                        DispatchTime.now().uptimeNanoseconds
                            - burstStart.uptimeNanoseconds
                    ) / 1_000_000_000
                Log.system(
                    String(
                        format: "tts burst: %d/%d frames in %.2fs",
                        burstSentFrames,
                        burstTotalFrames,
                        elapsed
                    )
                )
            }
        }

        // Absolute deadlines: a late tick self-corrects instead of
        // compounding into a systematically slow stream.
        let deadline = start + .milliseconds((frameIndex + 1) * 20)
        queue.asyncAfter(deadline: deadline) { [weak self] in
            self?.sendBurstFrames(
                burst,
                frameIndex: frameIndex + 1,
                gen: gen,
                start: start
            )
        }
    }

    private func dropPending() {
        generation += 1
        let dropped = pendingBursts
        pendingBursts.removeAll()
        for burst in dropped {
            burst.completion(false)
        }
    }
}
