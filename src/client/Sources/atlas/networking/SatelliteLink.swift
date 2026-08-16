import Accelerate
import Foundation
import Network

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

final class SatelliteLink: @unchecked Sendable {
    private enum FrameType: UInt8 {
        case mic = 0x01
        case tts = 0x02
        case control = 0x03
        case event = 0x04
    }

    private enum Control: UInt8 {
        case flush = 0x01
        case ttsStart = 0x02
    }

    private struct Burst {
        let pcm: Data
        let completion: (Bool) -> Void
    }

    private let port: UInt16
    private let onAudio: (UnsafePointer<Float>, Int) -> Void
    private let onDisconnect: () -> Void

    // All mutable state below is confined to `queue`.
    private let queue = DispatchQueue(
        label: "atlas.satellite",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "atlas.satellite.audio",
        qos: .userInitiated
    )

    private var listener: NWListener?
    private var connection: NWConnection?
    private var connected = false
    private var rxBuffer = Data()

    private var pendingBursts: [Burst] = []
    private var generation = 0
    private var senderActive = false

    private var debugMicTap: DebugMicTap?
    private var loggedFirstFrame = false

    private let frameBytes = 1_920
    private let paceInterval = DispatchTimeInterval.milliseconds(20)
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
        let listener = try NWListener(
            using: .tcp,
            on: NWEndpoint.Port(rawValue: port)!
        )
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func enqueue(pcm: Data, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.connected else {
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

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        rxBuffer = Data()

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .ready:
                self.connected = true
                Log.system("Satellite connected.")
            case .failed(let error):
                self.dropConnection(conn, reason: error.localizedDescription)
            case .cancelled:
                self.dropConnection(conn, reason: nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(conn)
    }

    private func dropConnection(_ conn: NWConnection, reason: String?) {
        guard connection === conn else {
            return
        }
        connection = nil
        connected = false

        dropPending()
        Log.system(
            "Satellite disconnected\(reason.map { ": \($0)" } ?? "")."
        )
        onDisconnect()
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, _, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.parseFrames()
            }
            if error == nil {
                self.receive(conn)
            }
        }
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
            Log.system("First mic frame received (\(payload.count) bytes).")
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

    private func runSender() {
        guard !pendingBursts.isEmpty else {
            senderActive = false
            return
        }
        let burst = pendingBursts.removeFirst()
        let gen = generation
        guard connected else {
            burst.completion(false)
            runSender()
            return
        }
        sendControl(.ttsStart)
        sendBurstFrames(burst, offset: 0, gen: gen)
    }

    private func sendBurstFrames(
        _ burst: Burst,
        offset: Int,
        gen: Int
    ) {
        guard gen == generation, connected else {
            burst.completion(false)
            runSender()
            return
        }
        if offset >= burst.pcm.count {
            queue.asyncAfter(deadline: .now() + drainMargin) { [weak self] in
                guard let self else {
                    return
                }
                burst.completion(gen == self.generation && self.connected)
                self.runSender()
            }
            return
        }
        let end = min(offset + frameBytes, burst.pcm.count)
        sendFrame(.tts, burst.pcm.subdata(in: offset..<end))
        queue.asyncAfter(deadline: .now() + paceInterval) { [weak self] in
            self?.sendBurstFrames(burst, offset: end, gen: gen)
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

    private func sendControl(_ control: Control) {
        sendFrame(.control, Data([control.rawValue]))
    }

    private func sendFrame(_ type: FrameType, _ payload: Data) {
        guard let conn = connection else {
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
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }
}
