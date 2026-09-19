import Foundation
import Darwin

public enum CaddyAdminError: Error, Equatable, Sendable {
    case invalidEndpoint
    case connectionFailed(String)
    case malformedResponse
    case httpFailure(Int, String)
}

public struct CaddyAdminClient: Sendable {
    public let endpoint: String

    public init(endpoint: String) { self.endpoint = endpoint }

    public func getConfig() throws -> Data {
        try request(method: "GET", path: "/config/", body: nil)
    }

    public func load(configuration: Data) throws -> Data {
        try request(method: "POST", path: "/load", body: configuration)
    }

    public func stop() throws -> Data {
        try request(method: "POST", path: "/stop", body: nil)
    }

    private func request(method: String, path: String, body: Data?) throws -> Data {
        guard endpoint.hasPrefix("unix//") else { throw CaddyAdminError.invalidEndpoint }
        let socketPath = String(endpoint.dropFirst("unix//".count))
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaddyAdminError.connectionFailed(String(cString: strerror(errno))) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CaddyAdminError.invalidEndpoint }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw CaddyAdminError.connectionFailed(String(cString: strerror(errno))) }

        var request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        } else {
            request += "Content-Length: 0\r\n\r\n"
        }
        var requestData = Data(request.utf8)
        if let body { requestData.append(body) }
        try sendAll(descriptor, data: requestData)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw CaddyAdminError.connectionFailed(String(cString: strerror(errno))) }
            response.append(buffer, count: count)
        }
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)), let header = String(data: response[..<separator.lowerBound], encoding: .utf8), let statusLine = header.split(separator: "\r\n").first else { throw CaddyAdminError.malformedResponse }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw CaddyAdminError.malformedResponse }
        let bodyStart = separator.upperBound
        let headerFields = header.split(separator: "\r\n").dropFirst()
        let chunked = headerFields.contains { field in
            let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[0].lowercased() == "transfer-encoding" && parts[1].lowercased().contains("chunked")
        }
        let responseBody = chunked ? try Self.decodeChunkedBody(Data(response[bodyStart...])) : Data(response[bodyStart...])
        guard (200..<300).contains(status) else { throw CaddyAdminError.httpFailure(status, String(data: responseBody, encoding: .utf8) ?? "") }
        return responseBody
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        let bytes = Array(data)
        var cursor = 0
        var body = Data()

        while true {
            guard let lineEnd = bytes[cursor...].firstIndex(of: 0x0A) else { throw CaddyAdminError.malformedResponse }
            let lineStart = cursor
            let lineStop = lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D ? lineEnd - 1 : lineEnd
            let sizeLine = String(decoding: bytes[lineStart..<lineStop], as: UTF8.self)
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
            guard let sizeToken, let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else { throw CaddyAdminError.malformedResponse }
            cursor = lineEnd + 1
            if size == 0 {
                while cursor < bytes.count {
                    guard let trailerEnd = bytes[cursor...].firstIndex(of: 0x0A) else { throw CaddyAdminError.malformedResponse }
                    let trailerStart = cursor
                    cursor = trailerEnd + 1
                    if trailerEnd == trailerStart || (trailerEnd == trailerStart + 1 && bytes[trailerStart] == 0x0D) { return body }
                }
                return body
            }
            guard size <= bytes.count - cursor, bytes.count - cursor >= size + 2 else { throw CaddyAdminError.malformedResponse }
            body.append(contentsOf: bytes[cursor..<(cursor + size)])
            cursor += size
            guard bytes[cursor] == 0x0D, bytes[cursor + 1] == 0x0A else { throw CaddyAdminError.malformedResponse }
            cursor += 2
        }
    }

    private func sendAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard sent > 0 else { throw CaddyAdminError.connectionFailed(String(cString: strerror(errno))) }
                offset += sent
            }
        }
    }
}
