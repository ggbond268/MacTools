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

        settings.importIcon(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))
        let darkPayload = settings.imagePayload(for: NSAppearance(named: .darkAqua))

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertFalse(payload.isTemplate)
        XCTAssertFalse(darkPayload.isTemplate)
        XCTAssertEqual(payload.image.size, NSSize(width: 18, height: 18))

        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let reloadedPayload = reloadedSettings.imagePayload(for: NSAppearance(named: .aqua))
        let reloadedDarkPayload = reloadedSettings.imagePayload(for: NSAppearance(named: .darkAqua))
        XCTAssertTrue(reloadedSettings.hasCustomIcon)
        XCTAssertFalse(reloadedPayload.isTemplate)
        XCTAssertFalse(reloadedDarkPayload.isTemplate)
        XCTAssertEqual(reloadedPayload.image.size, NSSize(width: 18, height: 18))
    }

    func testDarkOnlyIconFallsBackToLightAppearance() throws {
        let sourceURL = try makeImageFile(name: "dark-only-icon.png", color: .systemPurple)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL, for: .dark)
        let darkData = try imageData(from: settings.imagePayload(for: NSAppearance(named: .darkAqua)).image)

        XCTAssertEqual(
            try imageData(from: settings.imagePayload(for: NSAppearance(named: .aqua)).image),
            darkData
        )

        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        XCTAssertEqual(
            try imageData(from: reloadedSettings.imagePayload(for: NSAppearance(named: .aqua)).image),
            darkData
        )
        XCTAssertEqual(
            try imageData(from: reloadedSettings.imagePayload(for: NSAppearance(named: .darkAqua)).image),
            darkData
        )
    }

    func testImportPersistsDistinctIconsForEachAppearance() throws {
        let lightURL = try makeImageFile(name: "light-icon.png", color: .systemBlue)
        let darkURL = try makeImageFile(name: "dark-icon.png", color: .systemOrange)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: lightURL, for: .light)
        settings.importIcon(from: darkURL, for: .dark)

        let lightPayload = settings.imagePayload(for: NSAppearance(named: .aqua))
        let darkPayload = settings.imagePayload(for: NSAppearance(named: .darkAqua))

        XCTAssertFalse(lightPayload.isTemplate)
        XCTAssertFalse(darkPayload.isTemplate)
        XCTAssertNotEqual(try imageData(from: lightPayload.image), try imageData(from: darkPayload.image))

        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let reloadedLightPayload = reloadedSettings.imagePayload(for: NSAppearance(named: .aqua))
        let reloadedDarkPayload = reloadedSettings.imagePayload(for: NSAppearance(named: .darkAqua))

        XCTAssertEqual(try imageData(from: reloadedLightPayload.image), try imageData(from: lightPayload.image))
        XCTAssertEqual(try imageData(from: reloadedDarkPayload.image), try imageData(from: darkPayload.image))
        XCTAssertNotEqual(
            try imageData(from: reloadedLightPayload.image),
            try imageData(from: reloadedDarkPayload.image)
        )
    }

    func testLegacySingleSelectionMigratesToBothAppearances() throws {
        let sourceURL = try makeImageFile(name: "legacy-source.png", color: .systemPurple)
        let fileName = "legacy-icon.png"
        try installStoredImage(from: sourceURL, fileName: fileName)

        let legacyState = LegacyStoredState(localIconSelection: MenuBarIconLocalSelection(
            fileName: fileName,
            frameFileNames: [fileName],
            frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
        ))
        userDefaults.set(try JSONEncoder().encode(legacyState), forKey: "menubar.icon.settings")

        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        XCTAssertFalse(settings.imagePayload(for: NSAppearance(named: .aqua)).isTemplate)
        XCTAssertFalse(settings.imagePayload(for: NSAppearance(named: .darkAqua)).isTemplate)
    }

    func testLegacyAppearanceSelectionsMigrateFromRecentItems() throws {
        let lightSourceURL = try makeImageFile(name: "legacy-light-source.png", color: .systemBlue)
        let darkSourceURL = try makeImageFile(name: "legacy-dark-source.png", color: .systemOrange)
        let lightFileName = "legacy-light-icon.png"
        let darkFileName = "legacy-dark-icon.png"
        try installStoredImage(from: lightSourceURL, fileName: lightFileName)
        try installStoredImage(from: darkSourceURL, fileName: darkFileName)

        let state = LegacyAppearanceStoredState(
            lightIconFileName: lightFileName,
            darkIconFileName: darkFileName,
            recentItems: [
                MenuBarIconLocalSelection(
                    fileName: lightFileName,
                    frameFileNames: [lightFileName],
                    frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
                ),
                MenuBarIconLocalSelection(
                    fileName: darkFileName,
                    frameFileNames: [darkFileName],
                    frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
                )
            ]
        )
        userDefaults.set(try JSONEncoder().encode(state), forKey: "menubar.icon.settings")

        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        XCTAssertNotEqual(
            try imageData(from: settings.imagePayload(for: NSAppearance(named: .aqua)).image),
            try imageData(from: settings.imagePayload(for: NSAppearance(named: .darkAqua)).image)
        )
    }

    func testLegacyAppearanceSelectionsMigrateWithoutRecentItems() throws {
        let lightSourceURL = try makeImageFile(name: "legacy-light-source.png", color: .systemBlue)
        let darkSourceURL = try makeImageFile(name: "legacy-dark-source.png", color: .systemOrange)
        let lightFileName = "legacy-light-icon.png"
        let darkFileName = "legacy-dark-icon.png"
        try installStoredImage(from: lightSourceURL, fileName: lightFileName)
        try installStoredImage(from: darkSourceURL, fileName: darkFileName)

        let state = LegacyAppearanceStoredState(
            lightIconFileName: lightFileName,
            darkIconFileName: darkFileName,
            recentItems: nil
        )
        userDefaults.set(try JSONEncoder().encode(state), forKey: "menubar.icon.settings")

        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        XCTAssertNotEqual(
            try imageData(from: settings.imagePayload(for: NSAppearance(named: .aqua)).image),
            try imageData(from: settings.imagePayload(for: NSAppearance(named: .darkAqua)).image)
        )
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

        settings.importIcon(from: sourceURL, for: .light)
        settings.resetToDefault()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertTrue(settings.imagePayload(for: NSAppearance(named: .aqua)).isTemplate)
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

    private func imageData(from image: NSImage) throws -> Data {
        try XCTUnwrap(image.tiffRepresentation)
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

    private struct LegacyStoredState: Encodable {
        let localIconSelection: MenuBarIconLocalSelection
    }

    private struct LegacyAppearanceStoredState: Encodable {
        let lightIconFileName: String
        let darkIconFileName: String
        let recentItems: [MenuBarIconLocalSelection]?

        private enum CodingKeys: String, CodingKey {
            case lightIconFileName
            case darkIconFileName
            case recentItems
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lightIconFileName, forKey: .lightIconFileName)
            try container.encode(darkIconFileName, forKey: .darkIconFileName)
            try container.encodeIfPresent(recentItems, forKey: .recentItems)
        }
    }

}
