import Foundation

enum MsgPackValue {
    case string(String)
    case float(Float)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case array([MsgPackValue])
    case map([String: MsgPackValue])
    case null
}

enum MsgPack {
    static func encode(_ value: MsgPackValue) -> Data {
        var data = Data()
        write(value, into: &data)
        return data
    }

    static func decode(_ data: Data) -> MsgPackValue? {
        var index = data.startIndex
        return read(data, &index)
    }

    // MARK: - Encoding

    private static func write(_ value: MsgPackValue, into data: inout Data) {
        switch value {
        case .null:
            data.append(0xc0)
        case .bool(let b):
            data.append(b ? 0xc3 : 0xc2)
        case .int(let i):
            writeInt(i, into: &data)
        case .float(let f):
            data.append(0xca)
            appendBigEndianBytes(of: UInt64(f.bitPattern), byteCount: 4, into: &data)
        case .double(let d):
            data.append(0xcb)
            appendBigEndianBytes(of: d.bitPattern, byteCount: 8, into: &data)
        case .string(let s):
            writeString(s, into: &data)
        case .array(let arr):
            writeArrayHeader(arr.count, into: &data)
            for item in arr { write(item, into: &data) }
        case .map(let dict):
            writeMapHeader(dict.count, into: &data)
            for (k, v) in dict {
                writeString(k, into: &data)
                write(v, into: &data)
            }
        }
    }

    private static func writeInt(_ i: Int, into data: inout Data) {
        if i >= 0 && i <= 0x7f {
            data.append(UInt8(i))
        } else if i < 0 && i >= -32 {
            data.append(UInt8(bitPattern: Int8(i)))
        } else {
            data.append(0xd3)
            appendBigEndianBytes(of: UInt64(bitPattern: Int64(i)), byteCount: 8, into: &data)
        }
    }

    private static func writeString(_ s: String, into data: inout Data) {
        let utf8 = Array(s.utf8)
        let count = utf8.count
        if count <= 31 {
            data.append(0xa0 | UInt8(count))
        } else if count <= 0xff {
            data.append(0xd9)
            data.append(UInt8(count))
        } else if count <= 0xffff {
            data.append(0xda)
            appendBigEndianBytes(of: UInt64(count), byteCount: 2, into: &data)
        } else {
            data.append(0xdb)
            appendBigEndianBytes(of: UInt64(count), byteCount: 4, into: &data)
        }
        data.append(contentsOf: utf8)
    }

    private static func writeArrayHeader(_ count: Int, into data: inout Data) {
        if count <= 15 {
            data.append(0x90 | UInt8(count))
        } else if count <= 0xffff {
            data.append(0xdc)
            appendBigEndianBytes(of: UInt64(count), byteCount: 2, into: &data)
        } else {
            data.append(0xdd)
            appendBigEndianBytes(of: UInt64(count), byteCount: 4, into: &data)
        }
    }

    private static func writeMapHeader(_ count: Int, into data: inout Data) {
        if count <= 15 {
            data.append(0x80 | UInt8(count))
        } else if count <= 0xffff {
            data.append(0xde)
            appendBigEndianBytes(of: UInt64(count), byteCount: 2, into: &data)
        } else {
            data.append(0xdf)
            appendBigEndianBytes(of: UInt64(count), byteCount: 4, into: &data)
        }
    }

    private static func appendBigEndianBytes(
        of value: UInt64, byteCount: Int, into data: inout Data
    ) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    // MARK: - Decoding

    private static func read(_ data: Data, _ index: inout Data.Index) -> MsgPackValue? {
        guard index < data.endIndex else { return nil }
        let byte = data[index]
        index += 1

        switch byte {
        case 0x00...0x7f:
            return .int(Int(byte))
        case 0xe0...0xff:
            return .int(Int(Int8(bitPattern: byte)))
        case 0xc0:
            return .null
        case 0xc2:
            return .bool(false)
        case 0xc3:
            return .bool(true)
        case 0xca:
            guard let bits = readUInt(data, &index, byteCount: 4) else { return nil }
            return .double(Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))))
        case 0xcb:
            guard let bits = readUInt(data, &index, byteCount: 8) else { return nil }
            return .double(Double(bitPattern: bits))
        case 0xcc:
            guard let v = readUInt(data, &index, byteCount: 1) else { return nil }
            return .int(Int(v))
        case 0xcd:
            guard let v = readUInt(data, &index, byteCount: 2) else { return nil }
            return .int(Int(v))
        case 0xce:
            guard let v = readUInt(data, &index, byteCount: 4) else { return nil }
            return .int(Int(v))
        case 0xcf:
            guard let v = readUInt(data, &index, byteCount: 8) else { return nil }
            return .int(Int(v))
        case 0xd0:
            guard let v = readUInt(data, &index, byteCount: 1) else { return nil }
            return .int(Int(Int8(bitPattern: UInt8(v))))
        case 0xd1:
            guard let v = readUInt(data, &index, byteCount: 2) else { return nil }
            return .int(Int(Int16(bitPattern: UInt16(v))))
        case 0xd2:
            guard let v = readUInt(data, &index, byteCount: 4) else { return nil }
            return .int(Int(Int32(bitPattern: UInt32(v))))
        case 0xd3:
            guard let v = readUInt(data, &index, byteCount: 8) else { return nil }
            return .int(Int(Int64(bitPattern: v)))
        case 0xa0...0xbf:
            return readString(data, &index, length: Int(byte & 0x1f))
        case 0xd9:
            guard let length = readUInt(data, &index, byteCount: 1) else { return nil }
            return readString(data, &index, length: Int(length))
        case 0xda:
            guard let length = readUInt(data, &index, byteCount: 2) else { return nil }
            return readString(data, &index, length: Int(length))
        case 0xdb:
            guard let length = readUInt(data, &index, byteCount: 4) else { return nil }
            return readString(data, &index, length: Int(length))
        case 0x90...0x9f:
            return readArray(data, &index, count: Int(byte & 0x0f))
        case 0xdc:
            guard let count = readUInt(data, &index, byteCount: 2) else { return nil }
            return readArray(data, &index, count: Int(count))
        case 0xdd:
            guard let count = readUInt(data, &index, byteCount: 4) else { return nil }
            return readArray(data, &index, count: Int(count))
        case 0x80...0x8f:
            return readMap(data, &index, count: Int(byte & 0x0f))
        case 0xde:
            guard let count = readUInt(data, &index, byteCount: 2) else { return nil }
            return readMap(data, &index, count: Int(count))
        case 0xdf:
            guard let count = readUInt(data, &index, byteCount: 4) else { return nil }
            return readMap(data, &index, count: Int(count))
        case 0xc4:
            guard let length = readUInt(data, &index, byteCount: 1) else { return nil }
            index = data.index(index, offsetBy: Int(length))
            return .null
        case 0xc5:
            guard let length = readUInt(data, &index, byteCount: 2) else { return nil }
            index = data.index(index, offsetBy: Int(length))
            return .null
        case 0xc6:
            guard let length = readUInt(data, &index, byteCount: 4) else { return nil }
            index = data.index(index, offsetBy: Int(length))
            return .null
        default:
            return nil
        }
    }

    private static func readString(_ data: Data, _ index: inout Data.Index, length: Int)
        -> MsgPackValue?
    {
        guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else {
            return nil
        }
        let bytes = data[index..<end]
        index = end
        return .string(String(decoding: bytes, as: UTF8.self))
    }

    private static func readArray(_ data: Data, _ index: inout Data.Index, count: Int)
        -> MsgPackValue?
    {
        var items: [MsgPackValue] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let item = read(data, &index) else { return nil }
            items.append(item)
        }
        return .array(items)
    }

    private static func readMap(_ data: Data, _ index: inout Data.Index, count: Int)
        -> MsgPackValue?
    {
        var dict: [String: MsgPackValue] = [:]
        for _ in 0..<count {
            guard let keyValue = read(data, &index) else { return nil }
            guard case .string(let key) = keyValue else { return nil }
            guard let value = read(data, &index) else { return nil }
            dict[key] = value
        }
        return .map(dict)
    }

    private static func readUInt(_ data: Data, _ index: inout Data.Index, byteCount: Int) -> UInt64?
    {
        guard let end = data.index(index, offsetBy: byteCount, limitedBy: data.endIndex) else {
            return nil
        }
        var result: UInt64 = 0
        var cursor = index
        while cursor < end {
            result = (result << 8) | UInt64(data[cursor])
            cursor = data.index(after: cursor)
        }
        index = end
        return result
    }
}
