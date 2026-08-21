import Foundation

/// Debug-only guard that the byte prefix shared between consecutive LLM
/// requests never shrinks. vLLM prefix-cache blocks are hash-chained, so a
/// stable/growing shared prefix across turns is exactly the condition that
/// makes warm prefills possible; any shrink is a cache regression.
///
/// All work is gated by `Config.llmPrefixStabilityCheck`. When the flag is
/// off, each call is a single bool check — no storage, no comparison.
///
/// Call `check(_:)` with the encoded request body right before it goes on
/// the wire (conversation path only — one-shot generators have unrelated
/// prompts by design). Call `reset()` at legitimate prefix discontinuities:
/// conversation start/end and history-window trims.
enum LLMPrefixStability {
    private static let lock = NSLock()
    private static var lastBody: Data?
    private static var lastMatchLength = 0

    static func check(_ body: Data) {
        guard Config.llmPrefixStabilityCheck else { return }
        lock.lock()
        defer { lock.unlock() }

        guard let previous = lastBody else {
            lastBody = body
            lastMatchLength = 0
            return
        }

        let match = commonPrefixLength(previous, body)
        if match < lastMatchLength {
            Log.system(
                """
                [prefix-stability] shared prefix SHRANK: \
                \(lastMatchLength) -> \(match) bytes at offset \(match)
                previous: …\(excerpt(previous, around: match))
                current:  …\(excerpt(body, around: match))
                """
            )
        }

        lastBody = body
        lastMatchLength = match
    }

    static func reset() {
        guard Config.llmPrefixStabilityCheck else { return }
        lock.lock()
        defer { lock.unlock() }
        lastBody = nil
        lastMatchLength = 0
    }

    private static func commonPrefixLength(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                let x = pa.bindMemory(to: UInt8.self)
                let y = pb.bindMemory(to: UInt8.self)
                while i < n && x[i] == y[i] { i += 1 }
            }
        }
        return i
    }

    private static func excerpt(_ data: Data, around offset: Int) -> String {
        let lo = max(0, offset - 60)
        let hi = min(data.count, offset + 60)
        guard lo < hi else { return "" }
        return String(decoding: data.subdata(in: lo..<hi), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
    }
}
