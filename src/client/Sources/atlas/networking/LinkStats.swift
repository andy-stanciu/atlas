import Darwin
import Dispatch
import Foundation

enum LinkKind {
    case music, tts, other
}

struct WriteIO {
    var waits = 0
    var waitedMs = 0.0
    var err: Int32 = 0
    var dropped = false
}

final class LinkStats: @unchecked Sendable {
    static func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func msSince(_ ns: UInt64) -> Double {
        Double(nowNs() - ns) / 1_000_000
    }

    static func sndq(_ fd: Int32) -> Int32 {
        var n: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_NWRITE, &n, &len) == 0 else {
            return 0
        }
        return n
    }

    static func tcpInfo(_ fd: Int32) -> tcp_connection_info? {
        var info = tcp_connection_info()
        var len = socklen_t(MemoryLayout<tcp_connection_info>.size)
        guard getsockopt(fd, Int32(IPPROTO_TCP), TCP_CONNECTION_INFO, &info, &len) == 0 else {
            return nil
        }
        return info
    }

    private static func kb(_ bytes: Double) -> String {
        String(format: "%.1fKB", bytes / 1024)
    }

    private let lock = NSLock()
    private var windowStart = LinkStats.nowNs()
    private var musicOut = 0
    private var ttsOut = 0
    private var musicLagMax = 0.0
    private var backlogMax = 0
    private var dropBacklog = 0
    private var dropWrite = 0
    private var writeMax = 0.0
    private var eagain = 0
    private var waited = 0.0
    private var sndqMax: Int32 = 0
    private var rxBytes = 0
    private var ingestMax = 0.0
    private var lastRexmit: UInt64 = 0
    private var lastStallLog: UInt64 = 0

    func musicLag(_ ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        musicLagMax = max(musicLagMax, ms)
    }

    func musicBacklog(_ count: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        backlogMax = max(backlogMax, count)
        dropBacklog += dropped
    }

    func musicWriteDropped() {
        lock.lock()
        defer { lock.unlock() }
        dropWrite += 1
    }

    func write(_ kind: LinkKind, ms: Double, io: WriteIO, sndq: Int32) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .music: musicOut += 1
        case .tts: ttsOut += 1
        case .other: break
        }
        writeMax = max(writeMax, ms)
        eagain += io.waits
        waited += io.waitedMs
        sndqMax = max(sndqMax, sndq)
    }

    func ingest(bytes: Int, ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        rxBytes += bytes
        ingestMax = max(ingestMax, ms)
    }

    func snapshot(_ fd: Int32) -> String {
        var parts = ["sndq " + Self.kb(Double(Self.sndq(fd)))]
        if let i = Self.tcpInfo(fd) {
            parts.append("rtt \(i.tcpi_rttcur)ms srtt \(i.tcpi_srtt)ms rto \(i.tcpi_rto)ms")
            parts.append("peer wnd " + Self.kb(Double(i.tcpi_snd_wnd)))
            parts.append("cwnd \(i.tcpi_snd_cwnd) rexmit \(i.tcpi_txretransmitpackets)")
        }
        return parts.joined(separator: ", ")
    }

    func stall(_ what: String, fd: Int32) {
        guard Config.printLinkStalls else {
            return
        }
        lock.lock()
        let now = Self.nowNs()
        let allowed = now - lastStallLog > 1_000_000_000
        if allowed {
            lastStallLog = now
        }
        lock.unlock()
        guard allowed else {
            return
        }
        Log.linkStall("stall: \(what) | \(snapshot(fd))")
    }

    func emit(fd: Int32) {
        lock.lock()
        let now = Self.nowNs()
        let elapsed = Double(now - windowStart) / 1_000_000_000
        windowStart = now
        let active = musicOut + ttsOut + rxBytes + dropBacklog + dropWrite > 0
        var line = String(
            format:
                "%.1fs | music out %d (lag max %.0fms, backlog max %d, drop %d/%d) tts out %d"
                + " | write max %.0fms, eagain %d (%.0fms) | sndq max %@"
                + " | rx %@ (ingest max %.0fms)",
            elapsed, musicOut, musicLagMax, backlogMax, dropBacklog, dropWrite, ttsOut,
            writeMax, eagain, waited, Self.kb(Double(sndqMax)) as NSString,
            Self.kb(Double(rxBytes)) as NSString, ingestMax
        )
        musicOut = 0
        ttsOut = 0
        musicLagMax = 0
        backlogMax = 0
        dropBacklog = 0
        dropWrite = 0
        writeMax = 0
        eagain = 0
        waited = 0
        sndqMax = 0
        rxBytes = 0
        ingestMax = 0
        let previousRexmit = lastRexmit
        var newRexmit = lastRexmit
        var tcpPart = ""
        if let i = Self.tcpInfo(fd) {
            newRexmit = i.tcpi_txretransmitpackets
            tcpPart = String(
                format: " | tcp rtt %dms rto %dms peer wnd %@ rexmit +%d",
                Int(i.tcpi_rttcur), Int(i.tcpi_rto),
                Self.kb(Double(i.tcpi_snd_wnd)) as NSString,
                Int(newRexmit &- previousRexmit)
            )
            lastRexmit = newRexmit
        }
        lock.unlock()

        guard active else {
            return
        }
        line += tcpPart
        Log.link(line)
    }
}
