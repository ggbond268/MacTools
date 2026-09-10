import Foundation
import XCTest
@testable import MacTools

final class CLIArchiveTests: XCTestCase {
    static let fixture = Data(base64Encoded: "UEsDBBQAAAAIAAAAIQCKhDPAFAAAABIAAAAIAAAAbWFjdG9vbHNLy6woKS1K1U2tSE0uLUlMykkFAFBLAwQUAAAACAAAACEA4sRtkREAAAAPAAAABwAAAExJQ0VOU0VLy6woKS1K1c3JTE7NK04FAFBLAQIUAxQAAAAIAAAAIQCKhDPAFAAAABIAAAAIAAAAAAAAAAAAAADtgQAAAABtYWN0b29sc1BLAQIUAxQAAAAIAAAAIQDixG2REQAAAA8AAAAHAAAAAAAAAAAAAACkgToAAABMSUNFTlNFUEsFBgAAAAACAAIAawAAAHAAAAAAAA==")!

    func testPublisherZipShapeIsAccepted() throws { try CLIArchive.validate(Self.fixture) }

    func testRejectsTraversalDuplicatesSymlinksEncryptionAndLocalHeaderDisagreement() {
        // Central directory begins at 112; the second record follows at 166.
        let mutations: [(Int, UInt8)] = [
            (30, 47), (158, 47), // local and central filename tampering
            (120, 1), (6, 1), // encryption flags
            (153, 0xa1), // symlink mode in the central record
            (138, 0xff), // enormous expanded size
            (140, 0xff), // oversized name
            (156, 1), // wrong local offset
            (26, 1), // local name length differs
            (28, 1), // local extra field / zip64 unsupported
            (8, 12), // unexpected compression
        ]
        for (offset, value) in mutations {
            var bytes = Self.fixture
            bytes[offset] = value
            XCTAssertThrowsError(try CLIArchive.validate(bytes), "offset \(offset)")
        }
        for count in [0, 10, Self.fixture.count - 1] {
            XCTAssertThrowsError(try CLIArchive.validate(Self.fixture.prefix(count)))
        }
        XCTAssertThrowsError(try CLIArchive.validate(Self.fixture + Data([0])))
    }

    func testNativeSignatureCheckRejectsUnsignedExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mactools")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        XCTAssertThrowsError(try CLIArtifactVerifier.verifySignature(at: file,
            identifier: "test.mactools.nightly.cli", team: "TESTTEAM00", notarized: true))
    }

    func testProcessDeadlineAndOutputAreBounded() throws {
        XCTAssertThrowsError(try CLIProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05))
        XCTAssertThrowsError(try CLIProcess.run(URL(fileURLWithPath: "/usr/bin/yes"), [], limit: 64, timeout: 1))
    }
}
