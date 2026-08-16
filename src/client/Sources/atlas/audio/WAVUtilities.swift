import Foundation

func writeTemporaryWAV(
    pcm: Data,
    sampleRate: Int
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "voice-input-\(UUID().uuidString).wav"
        )

    try writeWAV(pcm: pcm, sampleRate: sampleRate, to: url)
    return url
}

func writeWAV(
    pcm: Data,
    sampleRate: Int,
    to url: URL
) throws {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16

    let byteRate =
        UInt32(sampleRate)
        * UInt32(channels)
        * UInt32(bitsPerSample / 8)

    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(pcm.count)
    let riffSize = 36 + dataSize

    var wav = Data()

    wav.append("RIFF".data(using: .ascii)!)
    appendLittleEndian(riffSize, to: &wav)

    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)

    appendLittleEndian(UInt32(16), to: &wav)
    appendLittleEndian(UInt16(1), to: &wav)
    appendLittleEndian(channels, to: &wav)
    appendLittleEndian(UInt32(sampleRate), to: &wav)
    appendLittleEndian(byteRate, to: &wav)
    appendLittleEndian(blockAlign, to: &wav)
    appendLittleEndian(bitsPerSample, to: &wav)

    wav.append("data".data(using: .ascii)!)
    appendLittleEndian(dataSize, to: &wav)
    wav.append(pcm)

    try wav.write(to: url)
}

private func appendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var littleEndian = value.littleEndian

    withUnsafeBytes(of: &littleEndian) {
        data.append(contentsOf: $0)
    }
}
