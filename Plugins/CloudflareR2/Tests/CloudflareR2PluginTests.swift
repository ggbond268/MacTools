import Foundation
import MacToolsPluginKit
import XCTest

@testable import CloudflareR2Plugin

@MainActor
final class CloudflareR2PluginTests: XCTestCase {
    func testMetadataPanelShortcutActionAndSettingsContracts() {
        let h = makeHarness()
        XCTAssertEqual(h.plugin.metadata.id, "cloudflare-r2")
        XCTAssertEqual(h.plugin.metadata.order, 75)
        XCTAssertEqual(h.plugin.metadata.title, "Cloudflare R2 上传")
        XCTAssertEqual(h.plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(h.plugin.primaryPanelDescriptor.buttonTitle, "选择")
        XCTAssertEqual(
            h.plugin.shortcutDefinitions.first?.actionID, CloudflareR2Plugin.ShortcutID.upload)
        XCTAssertEqual(
            h.plugin.actionDefinitions.first?.key.actionID, CloudflareR2Plugin.ActionID.upload)
        XCTAssertNotNil(h.plugin.settingsPage)
        XCTAssertTrue(h.plugin.primaryPanelState.isEnabled)
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传文件到 Cloudflare R2")
    }

    func testExecuteAndShortcutOpenPickerButUnknownActionDoesNot() {
        var count = 0
        let h = makeHarness(filePicker: {
            count += 1
            return nil
        })
        h.plugin.handleAction(.invokeAction(controlID: "other"))
        XCTAssertEqual(count, 0)
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(count, 1)
        h.plugin.handleShortcutAction(id: CloudflareR2Plugin.ShortcutID.upload)
        XCTAssertEqual(count, 2)
    }

    func testMenuUploadDoesNotImplicitlySavePartialConfigurationOrSecret() async {
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"))
        h.store.secretAccessKey = "half-written"
        h.store.accountID = "edited-but-unsaved"
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { if case .succeeded = h.plugin.status { true } else { false } }
        XCTAssertEqual(h.secrets.saveCount, 0)
        XCTAssertEqual(try? h.secrets.loadSecret(), "stored-secret")
        XCTAssertEqual(h.store.secretAccessKey, "half-written")
    }

    func testMissingConfigurationRequestsSettingsWithoutPicker() {
        var pickerCount = 0
        let h = makeHarness(
            configured: false,
            filePicker: {
                pickerCount += 1
                return nil
            })
        var settingsCount = 0
        h.plugin.requestSettingsPresentation = { settingsCount += 1 }
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(pickerCount, 0)
        XCTAssertEqual(settingsCount, 1)
        XCTAssertEqual(h.plugin.status, .failed("请先在设置中完成 R2 配置。"))
    }

    func testProgressUpdatesSubtitleAndCopyButtonCopiesPublicURL() async {
        let result = R2UploadResult(
            objectKey: "file.txt", url: URL(string: "https://files.example.com/file.txt"))
        let uploader = R2UploaderMock(outcome: .success(result), progressValues: [0.42])
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: uploader)
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        XCTAssertEqual(h.clipboard.values, ["https://files.example.com/file.txt"])
        XCTAssertEqual(h.notifier.notifications, [.init(fileName: "file.txt", result: result)])
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传完成：file.txt")
    }

    func testProgressUpdatesAreClampedAndDeduplicatedByPercentage() async {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "file.txt", url: nil)),
            progressValues: [0.421, 0.429, 0.42],
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: uploader
        )
        var stateChangeCount = 0
        h.plugin.onStateChange = { stateChangeCount += 1 }
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil {
            h.plugin.primaryPanelState.subtitle == "正在上传 file.txt… 42%"
        }
        XCTAssertEqual(stateChangeCount, 3)
        XCTAssertEqual(h.progressPresenter.requestedFileNames, ["file.txt"])
        XCTAssertEqual(h.progressPresenter.progressFileNames, ["file.txt"])
        XCTAssertEqual(h.progressPresenter.progressValues, [0.42])
        h.plugin.cancelUpload()
        XCTAssertEqual(h.progressPresenter.dismissCount, 2)
    }

    func testProgressRelayClampsAndOnlyReportsIncreasingWholePercentages() {
        let recorder = ProgressRecorderMock()
        let relay = R2ProgressRelay { recorder.append($0) }
        [-0.5, 0, 0.421, 0.429, 0.41, 1.5, 1].forEach(relay.report)
        XCTAssertEqual(recorder.values, [0.42, 1])
    }

    func testRenamedObjectNameIsPassedToUploaderAndCompletionDialog() async {
        let result = R2UploadResult(objectKey: "renamed.pdf", url: nil)
        let uploader = R2UploaderMock(outcome: .success(result))
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/original.pdf"),
            uploader: uploader,
            objectNameOverride: "renamed.pdf"
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        let objectNames = await uploader.objectNames
        XCTAssertEqual(objectNames, [Optional("renamed.pdf")])
        XCTAssertEqual(h.progressPresenter.progressFileNames, ["renamed.pdf"])
        XCTAssertEqual(
            h.notifier.notifications,
            [.init(fileName: "renamed.pdf", result: result)]
        )
    }

    func testExistingObjectCanBeOverwritten() async {
        let result = R2UploadResult(objectKey: "file.txt", url: nil)
        let checker = R2ObjectCheckerMock(results: [true])
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .success(result)),
            objectChecker: checker,
            conflictResolutions: [.overwrite]
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        let checkedNames = await checker.names
        XCTAssertEqual(checkedNames, ["file.txt"])
        XCTAssertEqual(h.progressPresenter.conflictingFileNames, ["file.txt"])
    }

    func testExistingObjectCanBeRenamedBeforeUpload() async {
        let result = R2UploadResult(objectKey: "renamed.txt", url: nil)
        let checker = R2ObjectCheckerMock(results: [true, false])
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .success(result)),
            objectNames: ["file.txt", "renamed.txt"],
            objectChecker: checker,
            conflictResolutions: [.rename]
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        let checkedNames = await checker.names
        XCTAssertEqual(checkedNames, ["file.txt", "renamed.txt"])
        XCTAssertEqual(h.progressPresenter.requestedFileNames.first, "file.txt")
        let suggestedName = h.progressPresenter.requestedFileNames.last
        XCTAssertNotEqual(suggestedName, "file.txt")
        XCTAssertEqual((suggestedName! as NSString).pathExtension, "txt")
        XCTAssertEqual(h.progressPresenter.progressFileNames, ["renamed.txt"])
    }

    func testCancellingConflictResolutionDoesNotUpload() async {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "file.txt", url: nil)))
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: uploader,
            objectChecker: R2ObjectCheckerMock(results: [true]),
            conflictResolutions: [.cancelled]
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .idle }
        let objectNames = await uploader.objectNames
        XCTAssertTrue(objectNames.isEmpty)
    }

    func testConflictCheckAndUploadUseSameConfigurationSnapshot() async {
        let result = R2UploadResult(objectKey: "file.txt", url: nil)
        let uploader = R2UploaderMock(outcome: .success(result))
        let checker = R2ObjectCheckerMock(results: [true])
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: uploader,
            objectChecker: checker,
            conflictResolutions: [.overwrite],
            mutateConfigurationOnConflict: true
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }

        let checkedConfigurations = await checker.configurations
        let uploadConfigurations = await uploader.configurations
        let checkedSecrets = await checker.secrets
        let uploadSecrets = await uploader.secrets
        XCTAssertEqual(checkedConfigurations.map(\.bucket), ["bucket"])
        XCTAssertEqual(uploadConfigurations.map(\.bucket), ["bucket"])
        XCTAssertEqual(checkedSecrets, ["stored-secret"])
        XCTAssertEqual(uploadSecrets, ["stored-secret"])
        XCTAssertEqual(h.store.bucket, "changed-bucket")
    }

    func testRandomUploadNamePreservesExtension() {
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        XCTAssertEqual(
            R2UploadNameGenerator.randomFileName(
                preservingExtensionOf: "archive.tar.gz",
                uuid: uuid
            ),
            "12345678-1234-1234-1234-1234567890ab.tar.gz"
        )
        XCTAssertEqual(
            R2UploadNameGenerator.randomFileName(
                preservingExtensionOf: "README",
                uuid: uuid
            ),
            "12345678-1234-1234-1234-1234567890ab"
        )
        XCTAssertEqual(
            R2UploadNameGenerator.randomFileName(
                preservingExtensionOf: "backup.tar.bz2",
                uuid: uuid
            ),
            "12345678-1234-1234-1234-1234567890ab.tar.bz2"
        )
    }

    func testPrivateSuccessShowsConfirmationWithoutCopying() async {
        let result = R2UploadResult(objectKey: "private/file.txt", url: nil)
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .success(result)))
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        XCTAssertTrue(h.clipboard.values.isEmpty)
        XCTAssertEqual(h.notifier.notifications, [.init(fileName: "file.txt", result: result)])
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传完成：private/file.txt")
    }

    func testDismissingPublicSuccessWithoutCopyLeavesClipboardUntouched() async {
        let result = R2UploadResult(
            objectKey: "file.txt", url: URL(string: "https://files.example.com/file.txt"))
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .success(result)), copyLinkOnNotification: false)
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        XCTAssertTrue(h.clipboard.values.isEmpty)
    }

    func testFailureUpdatesPanelWithoutSuccessSideEffects() async {
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .failure(.httpStatus(403))))
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { if case .failed = h.plugin.status { true } else { false } }
        XCTAssertEqual(h.plugin.status, .failed("上传失败（HTTP 403）。"))
        XCTAssertTrue(h.clipboard.values.isEmpty)
        XCTAssertTrue(h.notifier.notifications.isEmpty)
    }

    func testCancelReturnsToIdleAndLateCancelledErrorCannotOverwriteState() async {
        let uploader = R2UploaderMock(outcome: .failureURLCancelled, suspended: true)
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: uploader)
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status.isUploading }
        h.plugin.cancelUpload()
        XCTAssertEqual(h.plugin.status, .idle)
        await uploader.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.plugin.status, .idle)
    }

    func testActionAvailabilityAndInvocation() async throws {
        var pickerCount = 0
        let h = makeHarness(filePicker: {
            pickerCount += 1
            return URL(fileURLWithPath: "/tmp/action.txt")
        })
        let definition = try XCTUnwrap(h.plugin.actionDefinitions.first)
        let reference = ActionReference(key: definition.key)
        XCTAssertTrue(h.plugin.actionAvailability(for: reference).isAvailable)
        let invocation = ActionInvocation(reference: reference, source: .test, mode: .foreground)
        let handle = try h.plugin.beginAction(invocation)
        XCTAssertEqual(pickerCount, 0)
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(pickerCount, 1)
    }

    func testSettingsCancellationStopsActionUploadTask() async throws {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "action.txt", url: nil)),
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/action.txt"),
            uploader: uploader
        )
        let definition = try XCTUnwrap(h.plugin.actionDefinitions.first)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .test,
            mode: .foreground
        )
        let handle = try h.plugin.beginAction(invocation)
        let resultTask = Task { await handle.result() }
        await waitUntilUploaderStarts(uploader)
        h.plugin.cancelUpload()
        let actionResult = await resultTask.value
        XCTAssertEqual(actionResult, .cancelled)
        let wasCancelled = await uploader.wasCancelled
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(h.plugin.status, .idle)
    }

    func testProgressDialogCancelButtonStopsUpload() async {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "file.txt", url: nil)),
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: uploader
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntilUploaderStarts(uploader)
        h.progressPresenter.cancel()
        await waitUntil { h.plugin.status == .idle }
        await waitUntilUploaderIsCancelled(uploader)
        let wasCancelled = await uploader.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testDeactivationStopsActionUploadTask() async throws {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "action.txt", url: nil)),
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/action.txt"),
            uploader: uploader
        )
        let definition = try XCTUnwrap(h.plugin.actionDefinitions.first)
        let handle = try h.plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .test,
                mode: .foreground
            ))
        let resultTask = Task { await handle.result() }
        await waitUntilUploaderStarts(uploader)
        h.plugin.deactivate(reason: .uninstalling)
        let actionResult = await resultTask.value
        let wasCancelled = await uploader.wasCancelled
        XCTAssertEqual(actionResult, .cancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(h.plugin.status, .idle)
    }

    func testTerminalStatusReturnsToIdle() async {
        let result = R2UploadResult(objectKey: "file.txt", url: nil)
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .success(result)),
            terminalStatusDuration: .milliseconds(1)
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .idle }
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传文件到 Cloudflare R2")
    }

    func testStatusDerivedValues() {
        XCTAssertEqual(R2UploadStatus.preparing("file").subtitle, "准备上传 file…")
        XCTAssertEqual(R2UploadStatus.uploading("file", progress: 0.42).subtitle, "正在上传 file… 42%")
        XCTAssertTrue(R2UploadStatus.uploading("file", progress: 0).isUploading)
        XCTAssertEqual(R2UploadStatus.failed("reason").errorMessage, "reason")
    }

    func testRuntimeLocalizationCoversPluginStatusValidationAndErrors() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let resource = try makeLocalizationBundle()
        defer { try? FileManager.default.removeItem(at: resource.directory) }
        let localization = PluginLocalization(bundle: resource.bundle)

        PluginRuntimeLocalization.source.setPreference("en")
        let h = makeHarness(configured: false, resourceBundle: resource.bundle)
        XCTAssertEqual(h.plugin.metadata.title, "Cloudflare R2 Upload")
        XCTAssertEqual(h.plugin.primaryPanelDescriptor.buttonTitle, "Choose")
        h.plugin.chooseAndUpload()
        XCTAssertEqual(h.plugin.status, .failed("Complete the R2 configuration in Settings first."))
        XCTAssertEqual(
            R2UploadStatus.uploading("file.txt", progress: 0.42).subtitle(
                localization: localization
            ),
            "Uploading file.txt… 42%"
        )
        h.store.publicBaseURL = "invalid"
        XCTAssertEqual(
            h.store.publicBaseURLValidationMessage,
            "Enter a valid address beginning with http:// or https://."
        )

        PluginRuntimeLocalization.source.setPreference("zh-Hant")
        XCTAssertEqual(h.plugin.actionDefinitions.first?.title, "選擇檔案並上傳至 R2")
        XCTAssertEqual(
            R2UploadError.httpStatus(403).message(localization: localization),
            "上傳失敗（HTTP 403）。"
        )
        XCTAssertEqual(
            h.store.publicBaseURLValidationMessage,
            "請輸入以 http:// 或 https:// 開頭的有效網址。"
        )
    }

    private func makeHarness(
        configured: Bool = true, fileURL: URL? = nil,
        uploader: R2UploaderMock = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "file.txt", url: nil))),
        filePicker: (@MainActor @Sendable () -> URL?)? = nil, copyLinkOnNotification: Bool = true,
        terminalStatusDuration: Duration? = nil, objectNameOverride: String? = nil,
        objectNames: [String] = [],
        objectChecker: R2ObjectCheckerMock = R2ObjectCheckerMock(results: [false]),
        conflictResolutions: [R2UploadConflictResolution] = [],
        mutateConfigurationOnConflict: Bool = false,
        resourceBundle: Bundle = .main
    ) -> Harness {
        let storage = R2MemoryStorage(
            values: configured
                ? ["account-id": "account", "bucket": "bucket", "access-key-id": "access"] : [:])
        let secrets = R2SecretStoreMock(secret: configured ? "stored-secret" : nil)
        let localization = PluginLocalization(bundle: resourceBundle)
        let store = R2ConfigurationStore(
            storage: storage,
            secrets: secrets,
            localization: localization
        )
        let clipboard = R2ClipboardMock()
        let notifier = R2CompletionNotifierMock(copyLink: copyLinkOnNotification)
        let picker: @MainActor @Sendable () -> URL? = filePicker ?? { fileURL }
        let progressPresenter = R2ProgressPresenterMock(
            objectNameOverride: objectNameOverride, objectNames: objectNames,
            conflictResolutions: conflictResolutions,
            onConflict: mutateConfigurationOnConflict ? { store.bucket = "changed-bucket" } : nil)
        let plugin = CloudflareR2Plugin(
            context: PluginRuntimeContext(
                pluginID: "cloudflare-r2",
                resourceBundle: resourceBundle,
                storage: storage
            ),
            uploader: uploader, objectChecker: objectChecker, configurationStore: store,
            filePicker: picker, clipboard: clipboard, completionNotifier: notifier,
            progressPresenter: progressPresenter, terminalStatusDuration: terminalStatusDuration)
        return Harness(
            plugin: plugin, store: store, secrets: secrets, clipboard: clipboard, notifier: notifier,
            progressPresenter: progressPresenter)
    }

    private func makeLocalizationBundle() throws -> (bundle: Bundle, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent(
            "CloudflareR2Tests.bundle",
            isDirectory: true
        )
        for (language, values) in [
            "en": [
                "action.upload.title": "Choose a File and Upload to R2",
                "error.configuration.openSettings":
                    "Complete the R2 configuration in Settings first.",
                "error.upload.http": "Upload failed (HTTP %d).",
                "metadata.description": "Upload files to Cloudflare R2",
                "metadata.title": "Cloudflare R2 Upload",
                "panel.button.choose": "Choose",
                "status.uploading": "Uploading %@… %d%%",
                "validation.publicURL":
                    "Enter a valid address beginning with http:// or https://.",
            ],
            "zh-Hant": [
                "action.upload.title": "選擇檔案並上傳至 R2",
                "error.configuration.openSettings": "請先在「設定」中完成 R2 設定。",
                "error.upload.http": "上傳失敗（HTTP %d）。",
                "metadata.description": "將檔案上傳至 Cloudflare R2",
                "metadata.title": "Cloudflare R2 上傳",
                "panel.button.choose": "選擇",
                "status.uploading": "正在上傳 %@… %d%%",
                "validation.publicURL":
                    "請輸入以 http:// 或 https:// 開頭的有效網址。",
            ],
        ] {
            let languageURL = bundleURL.appendingPathComponent(
                "\(language).lproj",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: languageURL,
                withIntermediateDirectories: true
            )
            try values.map { "\"\($0.key)\" = \"\($0.value)\";" }
                .joined(separator: "\n")
                .write(
                    to: languageURL.appendingPathComponent("Localizable.strings"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        return (try XCTUnwrap(Bundle(url: bundleURL)), directory)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private func waitUntilUploaderStarts(_ uploader: R2UploaderMock) async {
        for _ in 0..<500 {
            if await uploader.isWaitingForCancellation { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Uploader did not start")
    }

    private func waitUntilUploaderIsCancelled(_ uploader: R2UploaderMock) async {
        for _ in 0..<500 {
            if await uploader.wasCancelled {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct Harness {
    let plugin: CloudflareR2Plugin
    let store: R2ConfigurationStore
    let secrets: R2SecretStoreMock
    let clipboard: R2ClipboardMock
    let notifier: R2CompletionNotifierMock
    let progressPresenter: R2ProgressPresenterMock
}

private actor R2UploaderMock: R2Uploading {
    enum Outcome: Sendable {
        case success(R2UploadResult)
        case failure(R2UploadError)
        case failureURLCancelled
    }
    let outcome: Outcome
    let progressValues: [Double]
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended: Bool
    private(set) var wasCancelled = false
    private(set) var isWaitingForCancellation = false
    private(set) var objectNames: [String?] = []
    private(set) var configurations: [R2Configuration] = []
    private(set) var secrets: [String] = []
    init(outcome: Outcome, progressValues: [Double] = [], suspended: Bool = false) {
        self.outcome = outcome
        self.progressValues = progressValues
        self.suspended = suspended
    }
    func resume() {
        suspended = false
        continuation?.resume()
        continuation = nil
    }
    func upload(
        fileURL: URL, objectName: String?, configuration: R2Configuration, secretAccessKey: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> R2UploadResult {
        objectNames.append(objectName)
        configurations.append(configuration)
        secrets.append(secretAccessKey)
        progressValues.forEach(progress)
        if suspended {
            isWaitingForCancellation = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: {
                Task { await self.recordCancellationAndResume() }
            }
        }
        try Task.checkCancellation()
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        case .failureURLCancelled: throw URLError(.cancelled)
        }
    }
    private func recordCancellationAndResume() {
        wasCancelled = true
        isWaitingForCancellation = false
        suspended = false
        continuation?.resume()
        continuation = nil
    }
}

private actor R2ObjectCheckerMock: R2ObjectChecking {
    private var results: [Bool]
    private(set) var names: [String] = []
    private(set) var configurations: [R2Configuration] = []
    private(set) var secrets: [String] = []

    init(results: [Bool]) {
        self.results = results
    }

    func objectExists(
        objectName: String,
        configuration: R2Configuration,
        secretAccessKey: String
    ) async throws -> Bool {
        names.append(objectName)
        configurations.append(configuration)
        secrets.append(secretAccessKey)
        return results.isEmpty ? false : results.removeFirst()
    }
}

@MainActor
private final class R2ClipboardMock: R2ClipboardWriting {
    private(set) var values: [String] = []
    func copy(_ value: String) { values.append(value) }
}

@MainActor
private final class R2CompletionNotifierMock: R2UploadCompletionNotifying {
    struct Notification: Equatable {
        let fileName: String
        let result: R2UploadResult
    }
    let copyLink: Bool
    private(set) var notifications: [Notification] = []
    init(copyLink: Bool) { self.copyLink = copyLink }
    func notify(fileName: String, result: R2UploadResult) -> Bool {
        notifications.append(Notification(fileName: fileName, result: result))
        return copyLink
    }
}

private final class ProgressRecorderMock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []
    var values: [Double] { lock.withLock { storedValues } }
    func append(_ value: Double) { lock.withLock { storedValues.append(value) } }
}

@MainActor
private final class R2ProgressPresenterMock: R2UploadProgressPresenting {
    private let objectNameOverride: String?
    private var objectNames: [String]
    private var conflictResolutions: [R2UploadConflictResolution]
    private let onConflict: (() -> Void)?
    private(set) var requestedFileNames: [String] = []
    private(set) var progressFileNames: [String] = []
    private(set) var progressValues: [Double] = []
    private(set) var conflictingFileNames: [String] = []
    private(set) var dismissCount = 0
    private var cancellationHandler: (() -> Void)?

    init(
        objectNameOverride: String?,
        objectNames: [String] = [],
        conflictResolutions: [R2UploadConflictResolution] = [],
        onConflict: (() -> Void)? = nil
    ) {
        self.objectNameOverride = objectNameOverride
        self.objectNames = objectNames
        self.conflictResolutions = conflictResolutions
        self.onConflict = onConflict
    }

    func requestObjectName(fileName: String) async -> String? {
        requestedFileNames.append(fileName)
        if !objectNames.isEmpty {
            return objectNames.removeFirst()
        }
        return objectNameOverride ?? fileName
    }

    func requestConflictResolution(fileName: String) async -> R2UploadConflictResolution {
        conflictingFileNames.append(fileName)
        onConflict?()
        return conflictResolutions.isEmpty ? .overwrite : conflictResolutions.removeFirst()
    }

    func beginProgress(fileName: String, onCancel: @escaping @MainActor () -> Void) {
        progressFileNames.append(fileName)
        cancellationHandler = onCancel
    }

    func update(progress: Double) {
        progressValues.append(progress)
    }

    func dismiss() {
        dismissCount += 1
        cancellationHandler = nil
    }

    func cancel() {
        cancellationHandler?()
    }
}
