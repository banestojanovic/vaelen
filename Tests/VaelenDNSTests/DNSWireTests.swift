import XCTest
@testable import VaelenDNSCore

final class DNSWireTests: XCTestCase {
    func testAResponseWithoutEDNS() throws {
        let response = try XCTUnwrap(DNSWire.response(for: query(name: "syncproof.test", type: 1)))
        XCTAssertEqual(response.count, 48)
        XCTAssertEqual(word(response, 0), 0x1234); XCTAssertEqual(word(response, 2) & 0x000f, 0)
        XCTAssertEqual(word(response, 4), 1); XCTAssertEqual(word(response, 6), 1); XCTAssertEqual(word(response, 10), 0)
        XCTAssertEqual(Array(response.suffix(4)), [127, 0, 0, 1])
    }

    func testEDNSIsOmittedAndCountsMatch() throws {
        let response = try XCTUnwrap(DNSWire.response(for: query(name: "syncproof.test", type: 1, edns: true)))
        XCTAssertEqual(word(response, 6), 1); XCTAssertEqual(word(response, 8), 0); XCTAssertEqual(word(response, 10), 0)
        XCTAssertEqual(response.count, 48)
    }

    func testAAAAHasNoAAnswer() throws {
        let response = try XCTUnwrap(DNSWire.response(for: query(name: "syncproof.test", type: 28)))
        XCTAssertEqual(word(response, 2) & 0x000f, 0); XCTAssertEqual(word(response, 6), 0); XCTAssertEqual(response.count, 32)
    }

    func testUnsupportedTypeIsValidAndTransactionAndQuestionArePreserved() throws {
        let request = query(name: "syncproof.test", type: 15)
        let response = try XCTUnwrap(DNSWire.response(for: request))
        XCTAssertEqual(word(response, 0), word(request, 0)); XCTAssertEqual(Array(response[12...]), Array(request[12..<request.count]))
    }

    func testOutsideTestIsNXDomainWithoutAnswer() throws {
        let response = try XCTUnwrap(DNSWire.response(for: query(name: "example.com", type: 1)))
        XCTAssertEqual(word(response, 2) & 0x000f, 3); XCTAssertEqual(word(response, 6), 0)
    }

    func testMalformedRequestIsRejected() { XCTAssertNil(DNSWire.response(for: [0, 1, 0, 0])) }

    private func query(name: String, type: UInt16, edns: Bool = false) -> [UInt8] {
        var packet: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, edns ? 1 : 0]
        for label in name.split(separator: ".") { packet.append(UInt8(label.utf8.count)); packet += label.utf8 }
        packet += [0, UInt8(type >> 8), UInt8(type), 0, 1]
        if edns { packet += [0, 0, 41, 0x04, 0xd0, 0, 0, 0, 0, 0, 0] }
        return packet
    }
    private func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
}
