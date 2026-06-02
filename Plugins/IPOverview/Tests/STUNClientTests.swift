import XCTest
@testable import IPOverviewPlugin

final class STUNClientTests: XCTestCase {
    private let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    /// Build a STUN Binding Success Response carrying a single XOR-MAPPED-ADDRESS
    /// attribute, so the parser can be exercised without any network I/O.
    private func bindingSuccessResponse(
        transactionID: [UInt8],
        family: UInt8,
        xPort: [UInt8],
        xAddress: [UInt8]
    ) -> Data {
        let attributeValue: [UInt8] = [0x00, family] + xPort + xAddress
        let attributeLength = attributeValue.count

        var bytes: [UInt8] = [0x01, 0x01] // Binding Success Response
        let messageLength = attributeLength + 4
        bytes += [UInt8((messageLength >> 8) & 0xff), UInt8(messageLength & 0xff)]
        bytes += cookie
        bytes += transactionID
        bytes += [0x00, 0x20] // attribute type: XOR-MAPPED-ADDRESS
        bytes += [UInt8((attributeLength >> 8) & 0xff), UInt8(attributeLength & 0xff)]
        bytes += attributeValue
        return Data(bytes)
    }

    func testDecodesXorMappedIPv6AddressAcrossAllSixteenBytes() {
        // Non-zero transaction ID is essential: with it, the previous bug (only
        // XOR-ing the first 4 bytes) decodes bytes 4...15 incorrectly, so this
        // test fails against the old code and passes only with the full-16-byte XOR.
        let transactionID: [UInt8] = [0xBA, 0xD0, 0xCA, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        let mask = cookie + transactionID // 16 bytes per RFC 5389
        // 2001:db8::1
        let address: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
        let xAddress = zip(address, mask).map { $0 ^ $1 }

        let data = bindingSuccessResponse(
            transactionID: transactionID,
            family: 0x02,
            xPort: [0x21, 0x12],
            xAddress: xAddress
        )

        XCTAssertEqual(STUNClient.parseMappedAddress(data, transactionID: transactionID), "2001:db8:0:0:0:0:0:1")
    }

    func testDecodesXorMappedIPv4Address() {
        let transactionID: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC]
        let address: [UInt8] = [203, 0, 113, 5]
        let xAddress = zip(address, cookie).map { $0 ^ $1 }

        let data = bindingSuccessResponse(
            transactionID: transactionID,
            family: 0x01,
            xPort: [0x21, 0x12],
            xAddress: xAddress
        )

        XCTAssertEqual(STUNClient.parseMappedAddress(data, transactionID: transactionID), "203.0.113.5")
    }

    func testRejectsResponseWithMismatchedTransactionID() {
        let transactionID: [UInt8] = Array(repeating: 0xAB, count: 12)
        let address: [UInt8] = [203, 0, 113, 5]
        let xAddress = zip(address, cookie).map { $0 ^ $1 }
        let data = bindingSuccessResponse(
            transactionID: transactionID,
            family: 0x01,
            xPort: [0x21, 0x12],
            xAddress: xAddress
        )

        let wrongTransactionID: [UInt8] = Array(repeating: 0x00, count: 12)
        XCTAssertNil(STUNClient.parseMappedAddress(data, transactionID: wrongTransactionID))
    }
}
