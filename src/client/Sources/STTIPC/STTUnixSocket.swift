import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum STTUnixSocketError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case connectFailed
    case acceptFailed
}

public enum STTUnixSocket {
    public static func makeServer(path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw STTUnixSocketError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cPtr in
                path.withCString { strncpy(cPtr, $0, 103) }
            }
        }

        let size = MemoryLayout<sockaddr_un>.size
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(size))
            }
        }

        guard bindResult == 0 else {
            throw STTUnixSocketError.bindFailed
        }

        guard listen(fd, 8) == 0 else {
            throw STTUnixSocketError.listenFailed
        }

        return fd
    }

    public static func accept(_ listenFD: Int32) throws -> Int32 {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else {
            throw STTUnixSocketError.acceptFailed
        }
        return fd
    }

    public static func connectClient(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw STTUnixSocketError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cPtr in
                path.withCString { strncpy(cPtr, $0, 103) }
            }
        }

        let size = MemoryLayout<sockaddr_un>.size
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(size))
            }
        }

        guard connectResult == 0 else {
            throw STTUnixSocketError.connectFailed
        }

        return fd
    }
}
