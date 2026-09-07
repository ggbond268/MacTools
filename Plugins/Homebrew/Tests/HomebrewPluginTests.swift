import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import HomebrewPlugin

@MainActor
final class HomebrewPluginTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
        super.tearDown()
    }
    
    // Fake runner for testing
    @MainActor
    final class FakeHomebrewCommandRunner: HomebrewCommandRunning {
        var stubbedStatus: Int32 = 0
        var stubbedOutputs: [String: String] = [:]
        var runCalls: [[String]] = []
        var isCancelled = false
        var cancelCount = 0
        var suspendNextRun = false
        var suspendCancelCompletion = false
        private var suspendedRunContinuation: CheckedContinuation<Int32, Never>?
        private var suspendedCancelContinuation: CheckedContinuation<Void, Never>?
        
        func run(
            executable: String,
            arguments: [String],
            onOutput: @escaping @MainActor (String) -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) async throws -> Int32 {
            runCalls.append(arguments)
            if suspendNextRun {
                suspendNextRun = false
                return await withCheckedContinuation { continuation in
                    suspendedRunContinuation = continuation
                }
            }
            
            // Determine stubbed output based on arguments
            var matchKey = ""
            if arguments.contains("tap") {
                matchKey = "tap"
            } else if arguments.contains("list") && arguments.contains("--formula") {
                matchKey = "list-formula"
            } else if arguments.contains("list") && arguments.contains("--cask") {
                matchKey = "list-cask"
            } else if arguments.contains("outdated") {
                matchKey = "outdated"
            } else if arguments.contains("info") && arguments.contains("--installed") {
                matchKey = "info-installed"
            } else if arguments.contains("search") && arguments.contains("--formula") {
                matchKey = "search-formula"
            } else if arguments.contains("search") && arguments.contains("--cask") {
                matchKey = "search-cask"
            }
            
            if let output = stubbedOutputs[matchKey] {
                onOutput(output)
            }
            
            return stubbedStatus
        }
        
        func cancel() async {
            isCancelled = true
            cancelCount += 1
            let continuation = suspendedRunContinuation
            suspendedRunContinuation = nil
            continuation?.resume(returning: 143)
            if suspendCancelCompletion {
                suspendCancelCompletion = false
                await withCheckedContinuation { continuation in
                    suspendedCancelContinuation = continuation
                }
            }
        }

        func releaseCancelCompletion() {
            let continuation = suspendedCancelContinuation
            suspendedCancelContinuation = nil
            continuation?.resume()
        }
    }
    
    func testMetadataIdentifiesHomebrewPlugin() {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        let localization = PluginLocalization(bundle: .main)
        let plugin = HomebrewPlugin(controller: controller, localization: localization)
        
        XCTAssertEqual(plugin.metadata.id, "homebrew")
        XCTAssertEqual(plugin.metadata.title, "Homebrew")
    }

    func testContextualSearchIsAvailableOnlyWhenHomebrewIsAvailable() {
        let controller = HomebrewController(runner: FakeHomebrewCommandRunner())
        let plugin = HomebrewPlugin(
            controller: controller,
            localization: PluginLocalization(bundle: .main)
        )

        controller.isBrewAvailable = false
        XCTAssertFalse(plugin.isSettingsSearchAvailable)
        controller.isBrewAvailable = true
        XCTAssertTrue(plugin.isSettingsSearchAvailable)
    }

    func testCanonicalMaintenanceActionsAreBoundedAndReportCommandCompletion() async throws {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"
        let plugin = HomebrewPlugin(controller: controller, localization: PluginLocalization(bundle: .main))

        XCTAssertEqual(
            plugin.actionDefinitions.map(\.key.actionID),
            ["update", "upgrade-all", "doctor", "cleanup"]
        )
        XCTAssertEqual(plugin.actionDefinitions.map(\.externalInvocationPolicy), Array(repeating: .unavailable, count: 4))
        XCTAssertEqual(plugin.actionDefinitions.map(\.risk), [.safe, .confirmationRequired, .safe, .confirmationRequired])
        XCTAssertTrue(plugin.actionDefinitions.allSatisfy { $0.executionTimeoutSeconds == 7_200 })
        XCTAssertTrue(plugin.actionDefinitions.allSatisfy {
            $0.capabilities.contains(.reportsProgress)
        })

        let doctor = try XCTUnwrap(plugin.actionDefinitions.first { $0.key.actionID == "doctor" })
        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: doctor.key),
                source: .actionGrid,
                mode: .background
            )
        )

        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(runner.runCalls, [["doctor"]])
        XCTAssertFalse(controller.isBusy)
    }

    func testUpdatingDeactivationCancelsAnActiveOperation() async {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        controller.isBusy = true
        let plugin = HomebrewPlugin(
            controller: controller,
            localization: PluginLocalization(bundle: .main)
        )

        plugin.deactivate(reason: .updating)
        for _ in 0 ..< 20 where runner.cancelCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(runner.cancelCount, 1)
        XCTAssertFalse(controller.isBusy)
    }

    func testUpdatingDeactivationStopsTheOwningScanSequence() async {
        let runner = FakeHomebrewCommandRunner()
        runner.suspendNextRun = true
        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"
        let plugin = HomebrewPlugin(
            controller: controller,
            localization: PluginLocalization(bundle: .main)
        )

        controller.scanAll()
        for _ in 0 ..< 100 where runner.runCalls.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(runner.runCalls, [["tap"]])

        plugin.deactivate(reason: .updating)
        for _ in 0 ..< 100 where controller.isBusy || runner.cancelCount == 0 {
            await Task.yield()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(runner.cancelCount, 1)
        XCTAssertEqual(runner.runCalls, [["tap"]])
        XCTAssertFalse(controller.isBusy)
    }

    func testStaleCancellationCleanupDoesNotClearReplacementScan() async {
        let runner = FakeHomebrewCommandRunner()
        runner.suspendNextRun = true
        runner.suspendCancelCompletion = true
        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"

        controller.scanAll()
        for _ in 0 ..< 100 where runner.runCalls.count < 1 {
            await Task.yield()
        }
        controller.cancelCurrentOperation()
        for _ in 0 ..< 100 where controller.isBusy {
            await Task.yield()
        }

        runner.suspendNextRun = true
        controller.scanAll()
        for _ in 0 ..< 100 where runner.runCalls.count < 2 {
            await Task.yield()
        }
        XCTAssertTrue(controller.isBusy)
        let replacementName = controller.currentOperationName

        runner.releaseCancelCompletion()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(controller.currentOperationName, replacementName)
        controller.cancelCurrentOperation()
        for _ in 0 ..< 100 where controller.isBusy {
            await Task.yield()
        }
        XCTAssertEqual(runner.cancelCount, 2)
    }

    func testCommandRunnerCancellationKillsDescendantProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomebrewCommandRunnerTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let brew = bin.appendingPathComponent("brew")
        let started = root.appendingPathComponent("started")
        let survived = root.appendingPathComponent("survived")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        # HOMEBREW cancellation fixture
        trap '' TERM
        (
          trap '' TERM
          sleep 1
          echo survived > "$1"
        ) &
        echo started > "$2"
        wait
        """.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: brew.path
        )
        let runner = HomebrewCommandRunner()
        let runTask = Task {
            try await runner.run(
                executable: brew.path,
                arguments: [survived.path, started.path],
                onOutput: { _ in },
                onError: { _ in }
            )
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: started.path),
              ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))

        await runner.cancel()
        let status = try await runTask.value
        try await Task.sleep(for: .milliseconds(1_100))

        XCTAssertNotEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: survived.path))
    }

    func testCommandRunnerWaitsForDescendantBeforeReturningSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomebrewCommandRunnerTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let brew = bin.appendingPathComponent("brew")
        let completed = root.appendingPathComponent("completed")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        # HOMEBREW descendant completion fixture
        (
          trap '' HUP TERM
          sleep 0.6
          echo completed > "$1"
        ) </dev/null >/dev/null 2>&1 &
        exit 0
        """.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: brew.path
        )
        let runner = HomebrewCommandRunner()

        let status = try await runner.run(
            executable: brew.path,
            arguments: [completed.path],
            onOutput: { _ in },
            onError: { _ in }
        )

        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
    }

    func testCommandRunnerCancellationAfterLeaderExitReturnsNonzero() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomebrewCommandRunnerTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let brew = bin.appendingPathComponent("brew")
        let started = root.appendingPathComponent("started")
        let completed = root.appendingPathComponent("completed")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        # HOMEBREW post-leader cancellation fixture
        (
          trap '' HUP TERM
          echo started > "$1"
          sleep 1
          echo completed > "$2"
        ) </dev/null >/dev/null 2>&1 &
        exit 0
        """.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: brew.path
        )
        let runner = HomebrewCommandRunner()
        let runTask = Task {
            try await runner.run(
                executable: brew.path,
                arguments: [started.path, completed.path],
                onOutput: { _ in },
                onError: { _ in }
            )
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: started.path),
              ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))

        await runner.cancel()
        let status = try await runTask.value
        try await Task.sleep(for: .milliseconds(1_100))

        XCTAssertNotEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
    }
    
    func testPanelUsesManageButton() {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        let localization = PluginLocalization(bundle: .main)
        let plugin = HomebrewPlugin(controller: controller, localization: localization)
        
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "管理")
        XCTAssertNil(plugin.primaryPanelState.detail)
    }

    func testManageButtonRequestsConfigurationPresentation() {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        let localization = PluginLocalization(bundle: .main)
        let plugin = HomebrewPlugin(controller: controller, localization: localization)
        var requestCount = 0
        plugin.requestSettingsPresentation = {
            requestCount += 1
        }

        plugin.handleAction(.invokeAction(controlID: HomebrewPlugin.ControlID.manage))

        XCTAssertEqual(requestCount, 1)
    }
    
    func testScanPopulatesPackagesAndTaps() async throws {
        let runner = FakeHomebrewCommandRunner()
        runner.stubbedOutputs = [
            "tap": "homebrew/core\nhomebrew/cask\n",
            "list-formula": "git 2.51.0\nripgrep 15.1.0\n",
            "list-cask": "iterm2 3.5.0\n",
            "outdated": "{\"formulae\":[{\"name\":\"git\",\"installed_versions\":[\"2.51.0\"],\"current_version\":\"2.55.0\",\"pinned\":false}],\"casks\":[]}",
            "info-installed": "{\"formulae\":[{\"name\":\"git\",\"desc\":\"Distributed revision control system\",\"homepage\":\"https://git-scm.com/\",\"dependencies\":[\"pcre2\",\"openssl\"]}],\"casks\":[]}"
        ]
        
        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true // override for testing
        controller.brewPath = "/opt/homebrew/bin/brew"
        
        // Trigger scan
        controller.scanAll()
        
        // Wait for async operations to settle in controller (robust wait loop)
        let deadline = Date().addingTimeInterval(5.0)
        while controller.isBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        
        XCTAssertEqual(controller.taps.count, 2)
        XCTAssertEqual(controller.taps.map(\.name), ["homebrew/core", "homebrew/cask"])
        
        XCTAssertEqual(controller.installedPackages.count, 3)
        let gitPkg = try XCTUnwrap(controller.installedPackages.first { $0.name == "git" })
        XCTAssertEqual(gitPkg.version, "2.51.0")
        XCTAssertEqual(gitPkg.latestVersion, "2.55.0")
        XCTAssertTrue(gitPkg.isOutdated)
        XCTAssertEqual(gitPkg.desc, "Distributed revision control system")
        XCTAssertEqual(gitPkg.homepage, "https://git-scm.com/")
        XCTAssertEqual(gitPkg.dependencies, ["pcre2", "openssl"])
        
        // Verify reverse dependency logic
        let ripPkg = try XCTUnwrap(controller.installedPackages.first { $0.name == "ripgrep" })
        XCTAssertFalse(ripPkg.isOutdated)
        XCTAssertEqual(ripPkg.requiredBy(in: controller.installedPackages), [])
    }

    func testSearchSkipsDuplicatePopulatedQuery() async throws {
        let runner = FakeHomebrewCommandRunner()
        runner.stubbedOutputs = [
            "search-formula": "wget\n",
            "search-cask": "warp\n"
        ]

        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"

        controller.search(query: "w")
        let deadline = Date().addingTimeInterval(5.0)
        while controller.isSearching && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(controller.searchResults.map(\.name), ["warp", "wget"])
        XCTAssertEqual(runner.runCalls.count, 2)

        controller.search(query: " w ")

        XCTAssertEqual(controller.searchResults.map(\.name), ["warp", "wget"])
        XCTAssertEqual(runner.runCalls.count, 2)
    }
    
    func testCustomPathPersistence() {
        UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let binDir = tempDir.appendingPathComponent("bin")
        let tempBrewFile = binDir.appendingPathComponent("brew")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? "#!/bin/sh\n# HOMEBREW test shim\n".write(to: tempBrewFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempBrewFile.path)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
        }
        
        // Test updating path
        controller.updateCustomPath(tempBrewFile.path)
        XCTAssertTrue(controller.isBrewAvailable)
        XCTAssertEqual(controller.brewPath, tempBrewFile.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "mactools.homebrew.customPath"), tempBrewFile.path)
        
        // Test empty path resets standard path discovery
        controller.updateCustomPath("")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "mactools.homebrew.customPath"), nil)
    }
    
    func testUnknownPanelActionIsIgnored() {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"

        let localization = PluginLocalization(bundle: .main)
        let plugin = HomebrewPlugin(controller: controller, localization: localization)

        plugin.handleAction(.invokeAction(controlID: "legacy-scan"))

        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(runner.runCalls.isEmpty)
    }

    func testCaskPackageActionsUseBrewSubcommandBeforeCaskFlag() async throws {
        let runner = FakeHomebrewCommandRunner()
        runner.stubbedStatus = 1

        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"

        let package = BrewPackage(
            name: "iterm2",
            version: "3.5.0",
            latestVersion: "3.5.0",
            isCask: true,
            desc: "",
            homepage: "",
            isOutdated: false,
            isPinned: false
        )

        controller.install(package: package)
        var deadline = Date().addingTimeInterval(5.0)
        while controller.isBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runner.runCalls.last, ["install", "--cask", "iterm2"])

        runner.runCalls.removeAll()
        controller.uninstall(package: package)
        deadline = Date().addingTimeInterval(5.0)
        while controller.isBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runner.runCalls.last, ["uninstall", "--cask", "iterm2"])

        runner.runCalls.removeAll()
        controller.upgrade(package: package)
        deadline = Date().addingTimeInterval(5.0)
        while controller.isBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runner.runCalls.last, ["upgrade", "--cask", "iterm2"])
    }
    
    func testPanelStateBusyAndNotAvailable() {
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)
        let localization = PluginLocalization(bundle: .main)
        let plugin = HomebrewPlugin(controller: controller, localization: localization)
        
        // Case 1: Not installed
        controller.isBrewAvailable = false
        var state = plugin.primaryPanelState
        XCTAssertNotNil(state.errorMessage)
        
        // Case 2: Available and Busy
        controller.isBrewAvailable = true
        controller.isBusy = true
        controller.currentOperationName = "Scanning..."
        state = plugin.primaryPanelState
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.subtitle, "Scanning...")
    }
    
    func testScanAllFailurePath() async throws {
        let runner = FakeHomebrewCommandRunner()
        runner.stubbedStatus = 1 // non-zero status indicating failure
        
        let controller = HomebrewController(runner: runner)
        controller.isBrewAvailable = true
        controller.brewPath = "/opt/homebrew/bin/brew"
        
        controller.scanAll()
        
        let deadline = Date().addingTimeInterval(5.0)
        while controller.isBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        
        // Verify logs contain system error entries
        let hasErrorLog = controller.logs.contains { $0.isError }
        XCTAssertTrue(hasErrorLog)
    }

    func testInvalidCustomPathIsRejected() {
        UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
        let runner = FakeHomebrewCommandRunner()
        let controller = HomebrewController(runner: runner)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let binDir = tempDir.appendingPathComponent("bin")
        let invalidBrewFile = binDir.appendingPathComponent("brew")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? "#!/bin/sh\n# not homebrew\n".write(to: invalidBrewFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalidBrewFile.path)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            UserDefaults.standard.removeObject(forKey: "mactools.homebrew.customPath")
        }

        controller.updateCustomPath(invalidBrewFile.path)

        XCTAssertNil(UserDefaults.standard.string(forKey: "mactools.homebrew.customPath"))
        XCTAssertNotEqual(controller.brewPath, invalidBrewFile.path)
        XCTAssertTrue(controller.logs.contains { $0.isError })
    }
}
