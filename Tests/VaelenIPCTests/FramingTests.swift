import XCTest
@testable import VaelenIPC

final class FramingTests: XCTestCase {
    func testDecoderHandlesSplitAndCoalescedFrames() throws {
        let encoder = FrameEncoder()
        let first = try encoder.encode(Data("first".utf8))
        let second = try encoder.encode(Data("second".utf8))
        var decoder = FrameDecoder()

        XCTAssertEqual(try decoder.append(first.prefix(2)), [])
        XCTAssertEqual(try decoder.append(first.dropFirst(2) + second), [Data("first".utf8), Data("second".utf8)])
        try decoder.finish()
    }

    func testDecoderRejectsOversizedFrame() throws {
        var decoder = FrameDecoder()
        var length = UInt32(FrameEncoder.maximumPayloadSize + 1).bigEndian
        let data = Data(bytes: &length, count: 4)

        XCTAssertThrowsError(try decoder.append(data)) { error in
            XCTAssertEqual(error as? FrameError, .frameTooLarge(FrameEncoder.maximumPayloadSize + 1))
        }
    }
}
