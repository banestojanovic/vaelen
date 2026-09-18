import Foundation

public enum DNSWire {
    private struct Query {
        let id: UInt16
        let flags: UInt16
        let question: [UInt8]
        let labels: [String]
        let type: UInt16
        let qclass: UInt16
    }

    public static func response(for packet: [UInt8]) -> [UInt8]? {
        guard let query = parse(packet) else { return nil }
        let authoritative = query.labels.last?.lowercased() == "test"
        let isA = query.type == 1 && query.qclass == 1 && authoritative
        var answer = [UInt8]()
        if isA {
            answer += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1]
        }
        var flags = UInt16(0x8000) // QR
        flags |= query.flags & 0x7800 // preserve opcode
        flags |= query.flags & 0x0100 // preserve RD; this server is not recursive
        if authoritative { flags |= 0x0400 } // AA
        let rcode: UInt16 = authoritative ? 0 : 3 // NXDOMAIN outside .test
        flags |= rcode
        var result = bytes(query.id) + bytes(flags)
        result += [0, 1] + bytes(UInt16(answer.isEmpty ? 0 : 1)) + [0, 0, 0, 0]
        result += query.question
        result += answer
        return result
    }

    private static func parse(_ packet: [UInt8]) -> Query? {
        guard packet.count >= 12 else { return nil }
        let id = word(packet, 0); let flags = word(packet, 2)
        guard flags & 0x8000 == 0, word(packet, 4) == 1 else { return nil }
        var cursor = 12
        guard let name = readName(packet, cursor: &cursor), cursor + 4 <= packet.count else { return nil }
        let questionEnd = cursor + 4
        let type = word(packet, cursor); let qclass = word(packet, cursor + 2)
        cursor = questionEnd
        guard word(packet, 6) == 0, word(packet, 8) == 0 else { return nil }
        // Validate all request additional records, including EDNS, but intentionally omit them from the response.
        for _ in 0..<Int(word(packet, 10)) {
            guard readName(packet, cursor: &cursor) != nil, cursor + 10 <= packet.count else { return nil }
            let rdlength = Int(word(packet, cursor + 8)); cursor += 10
            guard cursor + rdlength <= packet.count else { return nil }
            cursor += rdlength
        }
        guard cursor == packet.count else { return nil }
        return Query(id: id, flags: flags, question: Array(packet[12..<questionEnd]), labels: name, type: type, qclass: qclass)
    }

    private static func readName(_ packet: [UInt8], cursor: inout Int) -> [String]? {
        var labels = [String](); var position = cursor
        while position < packet.count {
            let length = Int(packet[position]); position += 1
            if length == 0 { cursor = position; return labels }
            guard length <= 63, position + length <= packet.count else { return nil }
            let label = String(decoding: packet[position..<(position + length)], as: UTF8.self)
            guard !label.isEmpty else { return nil }
            labels.append(label); position += length
        }
        return nil
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
    private static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
}
