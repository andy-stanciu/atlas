import Foundation

public enum STTRequestType: UInt8 {
    case begin = 0
    case append = 1
    case finish = 2
    case cancel = 3
    case ping = 4
}

public enum STTResponseType: UInt8 {
    case ok = 0
    case text = 1
    case error = 2
    case pong = 3
    case partial = 4
}

public enum STTFrameError: Error {
    case connectionClosed
    case malformedFrame
}

public enum STTIPCConfig {
    public static let socketPath = NSTemporaryDirectory() + "atlas-sttd.sock"
}

public final class STTFrameConnection {
    private let fd: Int32

    public init(fd: Int32) {
        self.fd = fd
    }

    public func close() {
        Foundation.close(fd)
    }

    public func writeFrame(type: UInt8, payload: Data) throws {
        var lengthBytes = UInt32(payload.count + 1).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &lengthBytes) { frame.append(contentsOf: $0) }
        frame.append(type)
        frame.append(payload)
        try writeAll(frame)
    }

    public func readFrame() throws -> (type: UInt8, payload: Data) {
        let lengthData = try readExactly(4)
        let length = lengthData.withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        guard length >= 1 else {
            throw STTFrameError.malformedFrame
        }

        let body = try readExactly(Int(length))
        return (type: body[body.startIndex], payload: body.dropFirst())
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                Foundation.write(fd, buffer.baseAddress, buffer.count)
            }

            if written <= 0 {
                throw STTFrameError.connectionClosed
            }

            offset += written
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0

        while offset < count {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Foundation.read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }

            if bytesRead <= 0 {
                throw STTFrameError.connectionClosed
            }

            offset += bytesRead
        }

        return Data(buffer)
    }
}
