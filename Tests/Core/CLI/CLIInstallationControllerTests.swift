import ServiceManagement
import XCTest
@testable import MacTools

@MainActor
final class CLIInstallationControllerTests: XCTestCase {
    func testInstallsAndRemovesOnlyOwnedSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("MacTools.app/Contents/MacOS/mactools")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: source.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        ))
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = CLIInstallationController(
            homeDirectory: root,
            bundledCLIURL: source
        )
        XCTAssertEqual(controller.status, .notInstalled)
        controller.install()
        XCTAssertEqual(controller.status, .installed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: controller.installURL.path),
            source.path
        )
        controller.uninstall()
        XCTAssertEqual(controller.status, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.installURL.path))
    }

    func testRefusesRegularFileConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source/mactools")
        let destination = root.appendingPathComponent(".local/bin/mactools")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: Data("keep".utf8)))
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = CLIInstallationController(homeDirectory: root, bundledCLIURL: source)
        XCTAssertEqual(controller.status, .conflict)
        controller.install()
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertEqual(controller.status, .conflict)
    }

    func testUnregisterFailureKeepsInstalledCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installation = CLIInstallationController(
            homeDirectory: fixture.root,
            bundledCLIURL: fixture.source
        )
        let service = FakeCLIInstallationBrokerService(status: .enabled)
        service.unregisterError = FakeCLIInstallationBrokerError.refused
        let serviceController = CLIBrokerServiceController(service: service)
        installation.install()

        installation.uninstallIntegration(using: serviceController)

        XCTAssertEqual(installation.status, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.installURL.path))
        XCTAssertNotNil(serviceController.lastError)
    }

    func testRegistrationFailureRollsBackInstalledCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installation = CLIInstallationController(
            homeDirectory: fixture.root,
            bundledCLIURL: fixture.source
        )
        let service = FakeCLIInstallationBrokerService(status: .notRegistered)
        service.registerError = FakeCLIInstallationBrokerError.refused
        let serviceController = CLIBrokerServiceController(service: service)

        installation.installIntegration(using: serviceController)

        XCTAssertEqual(installation.status, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.installURL.path))
        XCTAssertNotNil(serviceController.lastError)
    }

    func testRemovalFailureReregistersBrokerAndKeepsInstalledCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installation = CLIInstallationController(
            homeDirectory: fixture.root,
            bundledCLIURL: fixture.source,
            removeItem: { _ in throw FakeCLIInstallationBrokerError.refused }
        )
        let service = FakeCLIInstallationBrokerService(status: .enabled)
        let serviceController = CLIBrokerServiceController(service: service)
        installation.install()

        installation.uninstallIntegration(using: serviceController)

        XCTAssertEqual(installation.status, .installed)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertNotNil(installation.lastError)
    }

    func testRemovalFailureDoesNotRegisterAlreadyUnregisteredBroker() throws {
        try assertRemovalFailurePreservesAbsentBroker(status: .notRegistered)
    }

    func testRemovalFailureDoesNotRegisterMissingBroker() throws {
        try assertRemovalFailurePreservesAbsentBroker(status: .notFound)
    }

    private func makeFixture() throws -> (root: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("MacTools.app/Contents/MacOS/mactools")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: source.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        ))
        return (root, source)
    }

    private func assertRemovalFailurePreservesAbsentBroker(
        status: SMAppService.Status
    ) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installation = CLIInstallationController(
            homeDirectory: fixture.root,
            bundledCLIURL: fixture.source,
            removeItem: { _ in throw FakeCLIInstallationBrokerError.refused }
        )
        let service = FakeCLIInstallationBrokerService(status: status)
        let serviceController = CLIBrokerServiceController(service: service)
        installation.install()

        installation.uninstallIntegration(using: serviceController)

        XCTAssertEqual(installation.status, .installed)
        XCTAssertEqual(service.status, status)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertNotNil(installation.lastError)
    }
}

@MainActor
private final class FakeCLIInstallationBrokerService: CLIBrokerServicing {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private enum FakeCLIInstallationBrokerError: Error {
    case refused
}
