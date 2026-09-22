import Foundation
import MacToolsPluginKit
import XCTest

@testable import CloudflareR2Plugin

@MainActor
final class CloudflareR2PluginTests: XCTestCase {

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
        XCTAssertEqual(h.plugin.rowState.subtitle, "上传完成：file.txt")
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

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
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
