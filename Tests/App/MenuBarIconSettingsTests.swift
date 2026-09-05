import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarIconSettingsTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuBarIconSettingsTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarIconSettingsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try super.tearDownWithError()
    }

    func testImportPersistsCurrentCustomIcon() throws {
        let sourceURL = try makeImageFile(name: "status-icon.png", color: .systemBlue)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL)
        let payload = settings.imagePayload()

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertTrue(payload.isTemplate)
        XCTAssertTrue(payload.image.isTemplate)
        XCTAssertEqual(payload.image.size, NSSize(width: 18, height: 18))

        let storedData = try XCTUnwrap(userDefaults.data(forKey: "menubar.icon.settings"))
        let storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        XCTAssertNotNil(storedObject["localIconSelection"])
        XCTAssertNil(storedObject["lightIconSelection"])
        XCTAssertNil(storedObject["darkIconSelection"])

        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let reloadedPayload = reloadedSettings.imagePayload()
        XCTAssertTrue(reloadedSettings.hasCustomIcon)
        XCTAssertTrue(reloadedPayload.isTemplate)
        XCTAssertTrue(reloadedPayload.image.isTemplate)
        XCTAssertEqual(reloadedPayload.image.size, NSSize(width: 18, height: 18))
    }

    func testStoredAnimationMarksEveryFrameAsTemplate() throws {
        let firstFrameURL = try makeImageFile(name: "animation-frame-0.png", color: .systemBlue)
        let secondFrameURL = try makeImageFile(name: "animation-frame-1.png", color: .systemOrange)
        let frameFileNames = ["stored-frame-0.png", "stored-frame-1.png"]
        try installStoredImage(from: firstFrameURL, fileName: frameFileNames[0])
        try installStoredImage(from: secondFrameURL, fileName: frameFileNames[1])

        let state = StoredStateFixture(localIconSelection: MenuBarIconLocalSelection(
            fileName: frameFileNames[0],
            frameFileNames: frameFileNames,
            frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
        ))
        userDefaults.set(try JSONEncoder().encode(state), forKey: "menubar.icon.settings")

        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let payload = settings.imagePayload()

        XCTAssertTrue(payload.isAnimated)
        XCTAssertEqual(payload.animationFrames.count, frameFileNames.count)
        XCTAssertTrue(payload.animationFrames.allSatisfy(\.isTemplate))
    }

    func testRenderedImageNormalizesNonSquareSourceToStandardHeight() throws {
        let sourceURL = try makeImageFile(
            name: "wide.png",
            color: .systemOrange,
            size: NSSize(width: 120, height: 36)
        )
        let sourceImage = try XCTUnwrap(NSImage(contentsOf: sourceURL))

        let renderedImage = try XCTUnwrap(MenuBarIconProcessing.renderedImage(from: sourceImage))

        XCTAssertEqual(renderedImage.size.height, MenuBarIconProcessing.standardIconPointSize)
        XCTAssertGreaterThan(renderedImage.size.width, MenuBarIconProcessing.standardIconPointSize)
    }

    func testResetToDefaultClearsCustomSelection() throws {
        let sourceURL = try makeImageFile(name: "reset.png", color: .systemGreen)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL)
        settings.resetToDefault()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertTrue(settings.imagePayload().isTemplate)
    }

    private func makeImageFile(
        name: String,
        color: NSColor,
        size: NSSize = NSSize(width: 32, height: 32)
    ) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(MenuBarIconProcessing.pngData(from: image))
        try data.write(to: url)
        return url
    }

    private func installStoredImage(from sourceURL: URL, fileName: String) throws {
        let storedURL = rootDirectory
            .appendingPathComponent("MenuBarIcons", isDirectory: true)
            .appendingPathComponent("Recents", isDirectory: true)
            .appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: storedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: storedURL)
    }

    private struct StoredStateFixture: Encodable {
        let localIconSelection: MenuBarIconLocalSelection
    }

}
