import AppKit
import ImageIO
import UniformTypeIdentifiers
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

    func testResetToDefaultRestoresClassicFromLiveAndCustomSelections() throws {
        let sourceURL = try makeImageFile(name: "reset.png", color: .systemGreen)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.selectBuiltInIcon(.liveStatus)
        settings.resetToDefault()

        XCTAssertEqual(settings.selectedBuiltInIcon, .classic)
        XCTAssertFalse(settings.usesLiveStatusIcon)

        settings.selectBuiltInIcon(.liveStatus)
        settings.importIcon(from: sourceURL)
        settings.resetToDefault()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.selectedBuiltInIcon, .classic)
        XCTAssertFalse(settings.usesLiveStatusIcon)
        XCTAssertTrue(settings.imagePayload().isTemplate)
        let reloaded = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        XCTAssertEqual(reloaded.selectedBuiltInIcon, .classic)
    }

    func testFreshLegacyAndUnknownBuiltInSelectionsDefaultToClassic() {
        let storedValues: [String?] = [nil, "{}", #"{"builtInIcon":"future-icon"}"#]
        for storedValue in storedValues {
            userDefaults.removeObject(forKey: "menubar.icon.settings")
            if let storedValue {
                userDefaults.set(Data(storedValue.utf8), forKey: "menubar.icon.settings")
            }
            let persisted = userDefaults.data(forKey: "menubar.icon.settings")

            let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

            XCTAssertEqual(settings.selectedBuiltInIcon, .classic)
            XCTAssertFalse(settings.hasCustomIcon)
            XCTAssertFalse(settings.usesLiveStatusIcon)
            XCTAssertTrue(settings.imagePayload().isTemplate)
            XCTAssertEqual(settings.imagePayload().image.size, NSSize(width: 18, height: 18))
            XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), persisted)
        }
    }

    func testClassicSelectionPersistsAndUsesOriginalArtwork() throws {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.selectBuiltInIcon(.classic)

        let reloaded = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let payload = reloaded.imagePayload()
        let original = try XCTUnwrap(NSImage(named: "MenuBarIcon")?.copy() as? NSImage)
        original.size = NSSize(width: 18, height: 18)
        original.isTemplate = true

        XCTAssertEqual(reloaded.selectedBuiltInIcon, .classic)
        XCTAssertFalse(reloaded.hasCustomIcon)
        XCTAssertFalse(reloaded.usesLiveStatusIcon)
        XCTAssertTrue(payload.isTemplate)
        XCTAssertFalse(payload.isAnimated)
        XCTAssertEqual(payload.image.size, original.size)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(try displayPixels(payload.image, appearance: appearance), try displayPixels(original, appearance: appearance))
        }
    }

    func testClassicIgnoresLiveUpdatesUntilExplicitLiveSelectionWhichPersists() {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let image = settings.imagePayload().image
        let revision = settings.settingsRevision
        let persisted = userDefaults.data(forKey: "menubar.icon.settings")
        settings.updateSystemStatus(MenuBarSystemStatusSnapshot(
            battery: .level(fraction: 0.5, isCharging: true),
            wifi: .connected(level: 3), network: .connected, connectionKind: .wifi
        ))

        XCTAssertTrue(image === settings.imagePayload().image)
        XCTAssertEqual(settings.settingsRevision, revision)
        XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), persisted)

        settings.selectBuiltInIcon(.liveStatus)

        XCTAssertEqual(settings.selectedBuiltInIcon, .liveStatus)
        XCTAssertTrue(settings.usesLiveStatusIcon)
        XCTAssertEqual(settings.imagePayload().image.size, NSSize(width: 24, height: 24))
        XCTAssertFalse(settings.imagePayload().isTemplate)
        let reloaded = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        XCTAssertEqual(reloaded.selectedBuiltInIcon, .liveStatus)
        XCTAssertTrue(reloaded.usesLiveStatusIcon)
    }

    func testBuiltInCandidatePreviewDoesNotChangeSelection() {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        _ = settings.previewImage(for: .classic, appearance: .light)
        _ = settings.previewImage(for: .liveStatus, appearance: .dark)

        XCTAssertEqual(settings.selectedBuiltInIcon, .classic)
        XCTAssertFalse(settings.usesLiveStatusIcon)
        XCTAssertEqual(settings.settingsRevision, 0)
        XCTAssertNil(userDefaults.data(forKey: "menubar.icon.settings"))
    }

    func testBuiltInSelectionReplacesCustomIconAndAllowsAnotherImport() throws {
        let sourceURL = try makeImageFile(name: "built-in-switch.png", color: .black)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.importIcon(from: sourceURL)
        XCTAssertNil(settings.selectedBuiltInIcon)

        settings.selectBuiltInIcon(.classic)

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.selectedBuiltInIcon, .classic)
        settings.importIcon(from: sourceURL)
        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertNil(settings.selectedBuiltInIcon)
        XCTAssertFalse(settings.usesLiveStatusIcon)
    }

    func testLiveStatusRefreshesSelectedIconWithoutPersistingRuntimeData() throws {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.selectBuiltInIcon(.liveStatus)
        let persisted = try XCTUnwrap(userDefaults.data(forKey: "menubar.icon.settings"))
        let original = settings.imagePayload().image
        let revision = settings.settingsRevision
        let snapshot = MenuBarSystemStatusSnapshot(
            battery: .level(fraction: 0.7, isCharging: true),
            wifi: .connected(level: 4), network: .connected, connectionKind: .wifi
        )

        settings.updateSystemStatus(snapshot)

        XCTAssertFalse(original === settings.imagePayload().image)
        XCTAssertEqual(settings.settingsRevision, revision + 1)
        XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), persisted)
        XCTAssertFalse(settings.imagePayload().isAnimated)
        settings.updateSystemStatus(snapshot)
        XCTAssertEqual(settings.settingsRevision, revision + 1)
    }

    func testLiveStatusPreservesCustomImageUntilReset() throws {
        let sourceURL = try makeImageFile(name: "custom.png", color: .black)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.importIcon(from: sourceURL)
        let custom = settings.imagePayload().image
        let persisted = userDefaults.data(forKey: "menubar.icon.settings")
        let revision = settings.settingsRevision
        let snapshot = MenuBarSystemStatusSnapshot(
            battery: .level(fraction: 0.5, isCharging: false),
            wifi: .off, network: .connected, connectionKind: .ethernet
        )

        settings.updateSystemStatus(snapshot)

        XCTAssertTrue(custom === settings.imagePayload().image)
        XCTAssertEqual(settings.settingsRevision, revision)
        XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), persisted)
        settings.resetToDefault()
        XCTAssertFalse(custom === settings.imagePayload().image)
        XCTAssertEqual(settings.selectedBuiltInIcon, .classic)
        XCTAssertFalse(settings.usesLiveStatusIcon)
        XCTAssertEqual(settings.systemStatus, snapshot)
    }

    func testLiveColoredStatusPreservesOriginalRendering() {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.selectBuiltInIcon(.liveStatus)
        for battery in [
            MenuBarSystemStatusSnapshot.Battery.level(fraction: 0.7, isCharging: true),
            .level(fraction: 0.19, isCharging: false)
        ] {
            settings.updateSystemStatus(MenuBarSystemStatusSnapshot(battery: battery))

            let payload = settings.imagePayload()
            XCTAssertFalse(payload.isTemplate)
            XCTAssertFalse(payload.image.isTemplate)
            XCTAssertTrue(payload.animationFrames.allSatisfy { !$0.isTemplate })
            XCTAssertFalse(payload.isAnimated)
        }
    }

    func testLiveColoredImageCachesEachAppearance() throws {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.selectBuiltInIcon(.liveStatus)
        settings.updateSystemStatus(MenuBarSystemStatusSnapshot(
            battery: .level(fraction: 0.7, isCharging: true),
            wifi: .connected(level: 4), network: .connected, connectionKind: .wifi
        ))
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let light = settings.imagePayload(for: lightAppearance)
        let dark = settings.imagePayload(for: darkAppearance)

        XCTAssertFalse(light.image === dark.image)
        XCTAssertTrue(light.image === settings.imagePayload(for: lightAppearance).image)
        XCTAssertTrue(dark.image === settings.imagePayload(for: darkAppearance).image)
        XCTAssertTrue(light.image === settings.previewImage(for: .light))
        XCTAssertTrue(dark.image === settings.previewImage(for: .dark))
        XCTAssertNotEqual(
            try displayPixels(light.image, appearance: .aqua),
            try displayPixels(dark.image, appearance: .aqua)
        )
    }

    func testLiveIconReturnsToTemplateWhenBatteryColorStateEnds() {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.selectBuiltInIcon(.liveStatus)
        let transitions: [(MenuBarSystemStatusSnapshot.Battery, MenuBarSystemStatusSnapshot.Battery)] = [
            (
                .level(fraction: 0.7, isCharging: true),
                .level(fraction: 0.7, isCharging: false, isExternalPowerConnected: true)
            ),
            (
                .level(fraction: 0.19, isCharging: false),
                .level(fraction: 0.2, isCharging: false)
            )
        ]

        for (coloredBattery, normalBattery) in transitions {
            settings.updateSystemStatus(MenuBarSystemStatusSnapshot(battery: coloredBattery))
            let coloredLight = settings.previewImage(for: .light)
            let coloredDark = settings.previewImage(for: .dark)

            settings.updateSystemStatus(MenuBarSystemStatusSnapshot(battery: normalBattery))

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let payload = settings.imagePayload(for: NSAppearance(named: appearance))
                XCTAssertTrue(payload.isTemplate)
                XCTAssertTrue(payload.image.isTemplate)
                XCTAssertTrue(payload.animationFrames.allSatisfy(\.isTemplate))
                XCTAssertFalse(payload.image === coloredLight)
                XCTAssertFalse(payload.image === coloredDark)
            }
        }
    }

    func testOpaquePNGIsRejectedBeforeSaving() throws {
        let sourceURL = try makeImageFile(name: "opaque.png", color: .black, opaque: true)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL)

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.lastErrorMessage, MenuBarIconImportError.requiresTransparency.userMessage)
        XCTAssertNil(userDefaults.data(forKey: "menubar.icon.settings"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localIconsDirectory.path))
    }

    func testJPEGWithoutAlphaIsRejected() throws {
        let sourceURL = try makeImageFile(name: "opaque.jpg", color: .black, opaque: true, fileType: .jpeg)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL)

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.lastErrorMessage, MenuBarIconImportError.requiresTransparency.userMessage)
    }

    func testRejectedImagePreservesCurrentSelectionAndFiles() throws {
        let validURL = try makeImageFile(name: "valid.png", color: .black)
        let opaqueURL = try makeImageFile(name: "opaque.png", color: .black, opaque: true)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.importIcon(from: validURL)
        let originalData = userDefaults.data(forKey: "menubar.icon.settings")
        let originalImage = settings.imagePayload().image
        let originalRevision = settings.settingsRevision
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: localIconsDirectory.path).sorted()

        settings.importIcon(from: opaqueURL)

        XCTAssertNotNil(settings.lastErrorMessage)
        XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), originalData)
        XCTAssertTrue(settings.imagePayload().image === originalImage)
        XCTAssertEqual(settings.settingsRevision, originalRevision)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: localIconsDirectory.path).sorted(), originalFiles)
    }

    func testFullyTransparentImageIsRejected() throws {
        let sourceURL = try makeImageFile(name: "empty.png", color: .clear)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL)

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.lastErrorMessage, MenuBarIconImportError.requiresTransparency.userMessage)
    }

    func testRejectedImportPreservesGallerySelectionAndItsRenderingMode() throws {
        let sourceURL = try makeImageFile(name: "opaque.png", color: .black, opaque: true)
        let store = MenuBarIconRemoteAssetStore(rootDirectory: rootDirectory.appendingPathComponent("RemoteAssets"))
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory,
            remoteAssetStore: store
        )
        for renderingMode in [MenuBarIconRenderingMode.original, .template] {
            let selection = MenuBarIconRemoteAssetSelection(
                id: "gallery-fixture",
                version: "1",
                displayName: "Gallery Fixture",
                renderingMode: renderingMode,
                frameFileNames: ["frame.png"],
                frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
            )
            let frameURL = try XCTUnwrap(store.frameURLs(for: selection).first)
            try FileManager.default.createDirectory(at: frameURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: sourceURL).write(to: frameURL)
            settings.useRemoteAsset(selection)
            let originalData = userDefaults.data(forKey: "menubar.icon.settings")

            settings.importIcon(from: sourceURL)

            XCTAssertEqual(settings.selectedRemoteAsset, selection)
            XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), originalData)
            XCTAssertEqual(settings.imagePayload().isTemplate, renderingMode.isTemplate)
            XCTAssertTrue(FileManager.default.fileExists(atPath: frameURL.path))
        }
    }

    func testStoredOpaqueArtworkKeepsOriginalRenderingAndPersistence() throws {
        let sourceURL = try makeImageFile(name: "legacy.png", color: .black, opaque: true)
        try storeSelection(frameURLs: [sourceURL])
        let originalData = userDefaults.data(forKey: "menubar.icon.settings")
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        let payload = settings.imagePayload()

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertFalse(payload.isTemplate)
        XCTAssertFalse(payload.image.isTemplate)
        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), originalData)
        let templateCopy = try XCTUnwrap(payload.image.copy() as? NSImage)
        templateCopy.isTemplate = true
        XCTAssertNotEqual(
            try displayPixels(payload.image, appearance: .aqua),
            try displayPixels(templateCopy, appearance: .aqua)
        )
    }

    func testStoredMixedAnimationKeepsEveryFrameInOriginalMode() throws {
        let transparentURL = try makeImageFile(name: "transparent.png", color: .black)
        let opaqueURL = try makeImageFile(name: "opaque.png", color: .black, opaque: true)
        try storeSelection(frameURLs: [transparentURL, opaqueURL])
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        let payload = settings.imagePayload()

        XCTAssertTrue(payload.isAnimated)
        XCTAssertFalse(payload.isTemplate)
        XCTAssertEqual(payload.animationFrames.count, 2)
        XCTAssertTrue(payload.animationFrames.allSatisfy { !$0.isTemplate })
    }

    func testTransparentGIFImportsAndReloadsAsTemplate() async throws {
        let firstURL = try makeImageFile(name: "first.png", color: .black)
        let secondURL = try makeImageFile(name: "second.png", color: .black, circular: false)
        let animationURL = try makeGIF(frameURLs: [firstURL, secondURL])
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        await settings.importAnimation(from: animationURL)

        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertTrue(settings.imagePayload().isAnimated)
        let reloaded = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        XCTAssertEqual(reloaded.imagePayload().animationFrames.count, 2)
        XCTAssertTrue(reloaded.imagePayload().animationFrames.allSatisfy(\.isTemplate))
    }

    func testGIFWithOpaqueFrameIsRejectedWithoutReplacingSelection() async throws {
        let transparentURL = try makeImageFile(name: "transparent.png", color: .black)
        let opaqueURL = try makeImageFile(name: "opaque.png", color: .black, opaque: true)
        let animationURL = try makeGIF(frameURLs: [transparentURL, opaqueURL])
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.importIcon(from: transparentURL)
        let originalData = userDefaults.data(forKey: "menubar.icon.settings")
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: localIconsDirectory.path).sorted()

        await settings.importAnimation(from: animationURL)

        XCTAssertEqual(settings.lastErrorMessage, MenuBarIconImportError.requiresTransparency.userMessage)
        XCTAssertEqual(userDefaults.data(forKey: "menubar.icon.settings"), originalData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: localIconsDirectory.path).sorted(), originalFiles)
        XCTAssertFalse(settings.imagePayload().isAnimated)
    }

    func testBlankAnimationFramesAreAllowedWhenOtherFramesAreVisible() throws {
        let blankURL = try makeImageFile(name: "blank.png", color: .clear)
        let visibleURL = try makeImageFile(name: "visible.png", color: .black)
        let frames = try [blankURL, visibleURL].map { try XCTUnwrap(NSImage(contentsOf: $0)) }

        XCTAssertTrue(MenuBarIconProcessing.prepareFrames(from: frames).supportsTemplateRendering)
        XCTAssertFalse(MenuBarIconProcessing.prepareFrames(from: [frames[0], frames[0]]).supportsTemplateRendering)
    }

    func testTransparentArtworkRemainsDistinctInLightAndDarkRendering() throws {
        let circleURL = try makeImageFile(name: "circle.png", color: .black)
        let squareURL = try makeImageFile(name: "square.png", color: .black, circular: false)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.importIcon(from: circleURL)
        let circle = settings.imagePayload().image
        settings.importIcon(from: squareURL)
        let square = settings.imagePayload().image

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertNotEqual(try displayPixels(circle, appearance: appearance), try displayPixels(square, appearance: appearance))
        }
    }

    func testAppearanceChangesReusePreparedFrames() throws {
        let sourceURL = try makeImageFile(name: "icon.png", color: .black)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        settings.importIcon(from: sourceURL)

        let light = settings.imagePayload(for: NSAppearance(named: .aqua))
        let dark = settings.imagePayload(for: NSAppearance(named: .darkAqua))

        XCTAssertTrue(light.image === dark.image)
        XCTAssertTrue(light.isTemplate)
        XCTAssertTrue(dark.isTemplate)
    }

    private var localIconsDirectory: URL {
        rootDirectory.appendingPathComponent("MenuBarIcons/Recents", isDirectory: true)
    }

    private func storeSelection(frameURLs: [URL]) throws {
        let fileNames = frameURLs.indices.map { "stored-frame-\($0).png" }
        for (url, fileName) in zip(frameURLs, fileNames) {
            try installStoredImage(from: url, fileName: fileName)
        }
        let state = StoredStateFixture(localIconSelection: MenuBarIconLocalSelection(
            fileName: fileNames[0],
            frameFileNames: fileNames,
            frameDuration: 1.0 / MenuBarIconProcessing.animationFramesPerSecond
        ))
        userDefaults.set(try JSONEncoder().encode(state), forKey: "menubar.icon.settings")
    }

    private func makeGIF(frameURLs: [URL]) throws -> URL {
        let destinationURL = rootDirectory.appendingPathComponent("Fixtures/animation.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.gif.identifier as CFString, frameURLs.count, nil
        ))
        for url in frameURLs {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return destinationURL
    }

    private func displayPixels(_ image: NSImage, appearance: NSAppearance.Name) throws -> Data {
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        view.imageScaling = .scaleNone
        view.image = image
        view.appearance = NSAppearance(named: appearance)
        view.contentTintColor = appearance == .darkAqua ? .white : .black
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeImageFile(
        name: String,
        color: NSColor,
        size: NSSize = NSSize(width: 32, height: 32),
        opaque: Bool = false,
        circular: Bool = true,
        fileType: NSBitmapImageRep.FileType = .png
    ) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill(using: .copy)
        if opaque {
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        color.setFill()
        let contentBounds = NSRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        if circular {
            NSBezierPath(ovalIn: contentBounds).fill()
        } else {
            contentBounds.fill()
        }
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: fileType, properties: [:]))
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
