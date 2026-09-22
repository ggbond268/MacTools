import XCTest
@testable import DisplayVolumePlugin

final class Arm64DDCTransportTests: XCTestCase {
    private func reply(
        source: UInt8 = 0x6e,
        length: UInt8 = 0x88,
        opcode: UInt8 = 0x02,
        status: UInt8 = 0,
        feature: UInt8 = 0x62
    ) -> [UInt8] {
        let payload: [UInt8] = [source, length, opcode, status, feature, 0, 0, 100, 0, 40]
        return payload + [payload.reduce(UInt8(0x50), ^)]
    }

    func testValidVolumeReplyIsAccepted() throws {
        let value = try Arm64DDCTransport.parseReply(reply(), displayName: "Test display")
        XCTAssertEqual(value.current, 40)
        XCTAssertEqual(value.maximum, 100)
    }

    func testInvalidFieldsAreRejectedEvenWithValidChecksums() {
        for bytes in [
            reply(source: 0x91), reply(length: 0x08), reply(opcode: 3),
            reply(status: 1), reply(feature: 0x10)
        ] {
            XCTAssertThrowsError(try Arm64DDCTransport.parseReply(bytes, displayName: "Test display"))
        }
    }

    func testTruncatedAndOversizedRepliesAreRejected() {
        let valid = reply()
        for count in 0..<valid.count {
            XCTAssertThrowsError(try Arm64DDCTransport.parseReply(Array(valid.prefix(count)), displayName: "Test display"))
        }
        XCTAssertThrowsError(try Arm64DDCTransport.parseReply(valid + [0], displayName: "Test display"))
    }

    func testInvalidChecksumIsRejected() {
        var bytes = reply()
        bytes[10] ^= 1
        XCTAssertThrowsError(try Arm64DDCTransport.parseReply(bytes, displayName: "Test display"))
    }
}
