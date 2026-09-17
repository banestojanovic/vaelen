import Foundation

public enum FrameError: Error, Equatable, Sendable {
    case emptyFrame
    case frameTooLarge(Int)
    case unexpectedEndOfStream
}

public struct FrameEncoder: Sendable {
    public static let maximumPayloadSize = 1024 * 1024

    public init() {}

    public func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw FrameError.emptyFrame }
        guard payload.count <= Self.maximumPayloadSize else { throw FrameError.frameTooLarge(payload.count) }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }
}

public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let payloadSize = Int(length)
            guard payloadSize > 0 else { throw FrameError.emptyFrame }
            guard payloadSize <= FrameEncoder.maximumPayloadSize else {
                throw FrameError.frameTooLarge(payloadSize)
            }

            let frameSize = 4 + payloadSize
            guard buffer.count >= frameSize else { break }
            frames.append(Data(buffer[4..<frameSize]))
            buffer.removeSubrange(0..<frameSize)
        }

        return frames
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else { throw FrameError.unexpectedEndOfStream }
    }
}
