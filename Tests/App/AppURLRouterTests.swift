import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AppURLRouterTests: XCTestCase {
    func testDeferredInputValidationMatchesPublicAndRightClickRoutes() throws {
        XCTAssertTrue(
            AppURLRouter.acceptsDeferredInput(
                try XCTUnwrap(URL(string: "mactools://app/search")),
                acceptedSchemes: ["mactools"]
            )
        )
        XCTAssertTrue(
            AppURLRouter.acceptsDeferredInput(
                try XCTUnwrap(URL(string: "mactools://right-click/open-terminal?directory=/tmp")),
                acceptedSchemes: ["mactools"]
            )
        )
        XCTAssertFalse(
            AppURLRouter.acceptsDeferredInput(
                try XCTUnwrap(URL(string: "https://example.com")),
                acceptedSchemes: ["mactools"]
            )
        )
    }

    func testParserAcceptsDocumentedReleaseDebugAndNightlyRoutes() throws {
        let routes: [(String, AppDeepLink)] = [
            ("settings", .settings(.root)),
            ("settings/general", .settings(.general)),
            ("settings/about", .settings(.about)),
            ("settings/features/actions-and-shortcuts", .settings(.actionsAndShortcuts)),
            ("settings/features/automation", .settings(.automation)),
            ("settings/plugins/marketplace", .settings(.pluginMarketplace)),
            ("settings/plugins/fan-control", .settings(.pluginConfiguration("fan-control"))),
            ("panels/dashboard", .panel(.dashboard)),
            ("panels/feature", .panel(.feature)),
            ("search", .search)
        ]

        for scheme in ["mactools", "mactools-dev", "mactools-nightly"] {
            for (path, expected) in routes {
                let parsed = AppDeepLinkParser.parse(
                    try XCTUnwrap(URL(string: "\(scheme)://app/\(path)")),
                    acceptedSchemes: [scheme]
                )
                XCTAssertEqual(parsed, .success(expected), "Failed route: \(scheme)://app/\(path)")
            }
        }
    }

    func testParserAcceptsDocumentedActionAndPresetRoutesInAllSchemes() throws {
        let presetID = UUID(uuidString: "7B420000-0000-0000-0000-000000000001")!

        for scheme in ["mactools", "mactools-dev", "mactools-nightly"] {
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(
                        URL(string: "\(scheme)://app/actions/microphone-mute/toggle")
                    ),
                    acceptedSchemes: [scheme]
                ),
                .success(
                    .run(
                        .direct(
                            ActionKey(providerID: "microphone-mute", actionID: "toggle")
                        )
                    )
                )
            )
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(
                        URL(string: "\(scheme)://app/presets/\(presetID.uuidString)")
                    ),
                    acceptedSchemes: [scheme]
                ),
                .success(.run(.preset(presetID)))
            )
        }
    }

    func testNavigationOnlyParserDoesNotExecuteActionRoutes() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/actions/display-sleep/sleep")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.unsupportedRoute)
        )
    }

    func testActionParserRejectsParametersMalformedIDsAndEncodedSeparators() throws {
        let cases: [(String, AppURLRoutingError)] = [
            (
                "mactools://app/actions/display-sleep/sleep?confirm=false",
                .unexpectedActionParameters
            ),
            ("mactools://app/actions/display-sleep/sleep?", .unexpectedActionParameters),
            (
                "mactools://app/actions/display-sleep/sleep?x=1&x=2",
                .duplicatedParameter("x")
            ),
            ("mactools://app/actions/a/b", .malformedActionID),
            ("mactools://app/actions/display-sleep/bad%20id", .malformedActionID),
            ("mactools://app/actions/display-sleep/sleep%2Fnow", .unsupportedRoute),
            ("mactools://app/actions/display-sleep/%2E%2E", .unsupportedRoute),
            ("mactools://app/presets/not-a-uuid", .invalidPresetID),
            (
                "mactools://app/presets/7B420000-0000-0000-0000-000000000001?x=1",
                .unexpectedActionParameters
            ),
        ]

        for (urlString, expected) in cases {
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(URL(string: urlString)),
                    acceptedSchemes: ["mactools"]
                ),
                .failure(expected),
                "Unexpected result for \(urlString)"
            )
        }
    }

    func testParserToleratesTrailingSlashAndUniqueOptionalParameters() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/about/?source=website&campaign=launch")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .success(.settings(.about))
        )
    }

    func testParserDecodesSafeCharactersWithinIndividualPathSegments() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/fan%2Dcontrol")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .success(.settings(.pluginConfiguration("fan-control")))
        )
    }

    func testParserRejectsDuplicateParameters() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/search?source=website&source=docs")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.duplicatedParameter("source"))
        )
    }

    func testParserRejectsUnknownAndMalformedDestinations() throws {
        let cases: [(String, AppURLRoutingError)] = [
            ("not-a-url", .malformedURL),
            ("other://app/settings", .unsupportedScheme),
            ("mactools://other/settings", .unsupportedHost),
            ("mactools://app/settings/plugins/a", .malformedPluginID),
            ("mactools://app/settings/plugins/bad%20id", .malformedPluginID),
            ("mactools://app/settings/plugins/fan-control%0A", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control%0D", .unsupportedRoute),
            ("mactools://app/settings/unknown", .unsupportedRoute),
            ("mactools://app//settings", .unsupportedRoute),
            ("mactools://app/settings//", .unsupportedRoute),
            ("mactools://app/panels/dashboard//", .unsupportedRoute),
            ("mactools://app/search//", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control//", .unsupportedRoute),
            ("mactools://app/panels%2Fdashboard", .unsupportedRoute),
            ("mactools://app/panels%2fdashboard", .unsupportedRoute),
            ("mactools://app/settings%2Fplugins%2Ffan-control", .unsupportedRoute),
            ("mactools://app/panels%5Cdashboard", .unsupportedRoute),
            ("mactools://app/settings/%2E%2E/about", .unsupportedRoute),
            ("mactools://app/panels/%00dashboard", .unsupportedRoute),
            ("mactools://app/plugins/fan-control/commands/start", .unsupportedRoute),
            ("mactools://app/search?=value", .unsupportedURLComponents),
            ("mactools://app/settings#private", .unsupportedURLComponents),
            ("mactools://user@app/settings", .unsupportedURLComponents),
            ("mactools://app:/settings", .unsupportedURLComponents),
            ("mactools://app:42/settings", .unsupportedURLComponents)
        ]

        for (urlString, expectedError) in cases {
            let url = try XCTUnwrap(URL(string: urlString))
            XCTAssertEqual(
                AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
                .failure(expectedError),
                "Unexpected parser result for \(urlString)"
            )
        }
    }

    func testParserRejectsOversizedPublicURL() throws {
        let query = String(repeating: "x", count: AppDeepLinkParser.maximumURLByteCount)
        let url = try XCTUnwrap(URL(string: "mactools://app/search?metadata=\(query)"))

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.oversizedInput)
        )
    }

    func testRightClickRoutesDelegateImmediatelyBeforeActivationInBothBuildSchemes() throws {
        var delegatedURLs: [URL] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools", "mactools-dev"],
            rightClickHandler: { delegatedURLs.append($0) }
        )
        let releaseURL = try XCTUnwrap(
            URL(string: "mactools://right-click/new-folder?directory=/tmp")
        )
        let debugURL = try XCTUnwrap(
            URL(string: "mactools-dev://right-click/open-terminal?directory=/tmp")
        )

        XCTAssertEqual(router.handle(releaseURL), .delegatedToRightClick)
        XCTAssertEqual(router.handle(debugURL), .delegatedToRightClick)
        XCTAssertEqual(delegatedURLs, [releaseURL, debugURL])
    }

    func testRightClickCompatibilityNamespaceDoesNotAdoptPublicURLSizeLimit() throws {
        var delegatedURLs: [URL] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { delegatedURLs.append($0) }
        )
        let longPath = "/tmp/" + String(repeating: "a", count: AppDeepLinkParser.maximumURLByteCount)
        let url = try XCTUnwrap(
            URL(string: "mactools://right-click/open-terminal?directory=\(longPath)")
        )

        XCTAssertEqual(router.handle(url), .delegatedToRightClick)
        XCTAssertEqual(delegatedURLs, [url])
    }

    func testColdLaunchQueueDrainsInArrivalOrderAfterPluginInitialization() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in XCTFail("Unexpected Finder Sync delegation") }
        )
        let general = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let plugin = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/fan-control")
        )

        XCTAssertEqual(router.handle(general), .queued(.settings(.general)))
        XCTAssertEqual(
            router.handle(plugin),
            .queued(.settings(.pluginConfiguration("fan-control")))
        )
        XCTAssertTrue(requests.isEmpty)

        let drained = router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        XCTAssertEqual(
            drained,
            [
                .handled(.settings(.general)),
                .handled(.settings(.pluginConfiguration("fan-control")))
            ]
        )
        XCTAssertEqual(
            requests,
            [
                .settings(.general),
                .settings(.pluginConfiguration("fan-control"))
            ]
        )
    }

    func testUnavailablePluginIsRejectedWhenColdLaunchQueueDrains() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/not-installed")
        )

        XCTAssertEqual(
            router.handle(url),
            .queued(.settings(.pluginConfiguration("not-installed")))
        )
        XCTAssertEqual(
            router.activate(
                presentationHandler: { requests.append($0) },
                isPluginConfigurationAvailable: { _ in false }
            ),
            [.rejected(.unavailablePlugin("not-installed"))]
        )
        XCTAssertTrue(requests.isEmpty)
    }

    func testColdLaunchQueueRejectsOverflowWithoutDisplacingEarlierLinks() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            maximumPendingDeepLinks: 2,
            rightClickHandler: { _ in }
        )
        let general = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let about = try XCTUnwrap(URL(string: "mactools://app/settings/about"))
        let search = try XCTUnwrap(URL(string: "mactools://app/search"))

        XCTAssertEqual(router.handle(general), .queued(.settings(.general)))
        XCTAssertEqual(router.handle(about), .queued(.settings(.about)))
        XCTAssertEqual(router.handle(search), .rejected(.pendingQueueFull))

        router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { _ in true }
        )
        XCTAssertEqual(requests, [.settings(.general), .settings(.about)])
    }

    func testRepeatedPanelAndSearchLinksUseDeterministicPresentationRequests() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { _ in true }
        )
        let dashboard = try XCTUnwrap(URL(string: "mactools://app/panels/dashboard"))
        let feature = try XCTUnwrap(URL(string: "mactools://app/panels/feature"))
        let search = try XCTUnwrap(URL(string: "mactools://app/search"))

        XCTAssertEqual(router.handle(dashboard), .handled(.panel(.dashboard)))
        XCTAssertEqual(router.handle(dashboard), .handled(.panel(.dashboard)))
        XCTAssertEqual(router.handle(feature), .handled(.panel(.feature)))
        XCTAssertEqual(router.handle(search), .handled(.search))
        XCTAssertEqual(
            requests,
            [.showDashboard, .showDashboard, .showFeaturePanel, .showUnifiedSearch]
        )
    }

    func testMixedColdLaunchRoutesPreserveArrivalOrder() async throws {
        enum Event: Equatable {
            case navigation(AppPresentationRequest)
            case action(ActionRunLinkRequest)
        }
        var events: [Event] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in XCTFail("Unexpected delegation") }
        )
        let settings = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/display-sleep/sleep")
        )
        let search = try XCTUnwrap(URL(string: "mactools://app/search"))

        XCTAssertEqual(router.handle(settings), .queued(.settings(.general)))
        XCTAssertEqual(
            router.handle(action),
            .queuedAction(.direct(ActionKey(providerID: "display-sleep", actionID: "sleep")))
        )
        XCTAssertEqual(router.handle(search), .queued(.search))

        let synchronous = router.activate(
            presentationHandler: { request in events.append(.navigation(request)) },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { request, _ in
                events.append(.action(request))
                return .completed
            }
        )
        XCTAssertEqual(synchronous, [.handled(.settings(.general))])
        await router.waitUntilIdle()

        XCTAssertEqual(
            events,
            [
                .navigation(.settings(.general)),
                .action(
                    .direct(ActionKey(providerID: "display-sleep", actionID: "sleep"))
                ),
                .navigation(.showUnifiedSearch),
            ]
        )
    }

    func testActiveActionDeliveryIsSerializedAndBacklogIsBounded() async throws {
        var rejections: [(ActionRunLinkRequest, AppURLRoutingError)] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            maximumPendingDeepLinks: 2,
            rightClickHandler: { _ in },
            actionRejectionHandler: { request, error in
                rejections.append((request, error))
            }
        )
        var activeCount = 0
        var maximumActiveCount = 0
        var delivered: [ActionRunLinkRequest] = []
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { request, _ in
                activeCount += 1
                maximumActiveCount = max(maximumActiveCount, activeCount)
                delivered.append(request)
                try? await Task.sleep(for: .milliseconds(10))
                activeCount -= 1
                return .completed
            }
        )
        let first = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/first"))
        let second = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/second"))
        let overflow = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/third"))

        XCTAssertEqual(
            router.handle(first),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "first")))
        )
        XCTAssertEqual(
            router.handle(second),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "second")))
        )
        XCTAssertEqual(router.handle(overflow), .rejected(.pendingQueueFull))
        await router.waitUntilIdle()

        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(
            rejections.first?.0,
            .direct(ActionKey(providerID: "test-provider", actionID: "third"))
        )
        XCTAssertEqual(rejections.first?.1, .pendingQueueFull)
        XCTAssertEqual(maximumActiveCount, 1)
        XCTAssertEqual(
            delivered,
            [
                .direct(ActionKey(providerID: "test-provider", actionID: "first")),
                .direct(ActionKey(providerID: "test-provider", actionID: "second")),
            ]
        )
    }

    func testDuplicateActionIsRejectedWhileFirstRequestIsStillPending() async throws {
        var rejections: [(ActionRunLinkRequest, AppURLRoutingError)] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in },
            actionRejectionHandler: { request, error in
                rejections.append((request, error))
            }
        )
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/pending")
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "pending")
        )
        var handledRequests: [ActionRunLinkRequest] = []
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { _ in .success(reference) },
            actionHandler: { request, _ in
                handledRequests.append(request)
                return .completed
            }
        )

        XCTAssertEqual(router.handle(action), .queuedAction(.direct(reference.key)))
        XCTAssertEqual(router.handle(action), .rejected(.actionAlreadyRunning))
        await router.waitUntilIdle()

        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections.first?.0, .direct(reference.key))
        XCTAssertEqual(rejections.first?.1, .actionAlreadyRunning)
        XCTAssertEqual(handledRequests, [.direct(reference.key)])
    }

    func testPendingDirectActionAndPresetAliasShareCanonicalIdentity() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let presetID = UUID(uuidString: "7B420000-0000-4000-8000-000000000010")!
        let direct = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/aliased")
        )
        let preset = try XCTUnwrap(
            URL(string: "mactools://app/presets/\(presetID.uuidString)")
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "aliased")
        )
        var handledRequests: [ActionRunLinkRequest] = []
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { _ in .success(reference) },
            actionHandler: { request, _ in
                handledRequests.append(request)
                return .completed
            }
        )

        XCTAssertEqual(router.handle(direct), .queuedAction(.direct(reference.key)))
        XCTAssertEqual(router.handle(preset), .rejected(.actionAlreadyRunning))
        await router.waitUntilIdle()

        XCTAssertEqual(handledRequests, [.direct(reference.key)])
    }

    func testMutablePresetCollisionReportsDeferredRejectionInsteadOfSilentDrop() async throws {
        let firstPresetID = UUID(uuidString: "7B420000-0000-4000-8000-000000000011")!
        let secondPresetID = UUID(uuidString: "7B420000-0000-4000-8000-000000000012")!
        let firstPreset = try XCTUnwrap(
            URL(string: "mactools://app/presets/\(firstPresetID.uuidString)")
        )
        let secondPreset = try XCTUnwrap(
            URL(string: "mactools://app/presets/\(secondPresetID.uuidString)")
        )
        let firstReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "first")
        )
        let secondReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "second")
        )
        var referencesByPreset = [
            firstPresetID: firstReference,
            secondPresetID: secondReference,
        ]
        var deferredRejections: [(ActionRunLinkRequest, AppURLRoutingError)] = []
        var handledRequests: [ActionRunLinkRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in },
            actionRejectionHandler: { request, error in
                deferredRejections.append((request, error))
            }
        )
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { request in
                guard case let .preset(presetID) = request,
                      let reference = referencesByPreset[presetID] else {
                    return nil
                }
                return .success(reference)
            },
            actionHandler: { request, _ in
                handledRequests.append(request)
                return .completed
            }
        )

        XCTAssertEqual(router.handle(firstPreset), .queuedAction(.preset(firstPresetID)))
        XCTAssertEqual(router.handle(secondPreset), .queuedAction(.preset(secondPresetID)))
        referencesByPreset[secondPresetID] = firstReference
        await router.waitUntilIdle()

        XCTAssertEqual(handledRequests, [.preset(firstPresetID)])
        XCTAssertEqual(deferredRejections.count, 1)
        XCTAssertEqual(deferredRejections.first?.0, .preset(secondPresetID))
        XCTAssertEqual(deferredRejections.first?.1, .actionAlreadyRunning)
    }

    func testQueueOverflowDoesNotReserveRejectedActionIdentity() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            maximumPendingDeepLinks: 1,
            rightClickHandler: { _ in }
        )
        let navigation = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/retry")
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "retry")
        )
        var handledRequests: [ActionRunLinkRequest] = []

        XCTAssertEqual(router.handle(navigation), .queued(.settings(.general)))
        XCTAssertEqual(router.handle(action), .rejected(.pendingQueueFull))

        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { _ in .success(reference) },
            actionHandler: { request, _ in
                handledRequests.append(request)
                return .completed
            }
        )
        XCTAssertEqual(router.handle(action), .queuedAction(.direct(reference.key)))
        await router.waitUntilIdle()

        XCTAssertEqual(handledRequests, [.direct(reference.key)])
    }

    func testActiveActionCannotRecursivelyQueueItself() async throws {
        var rejections: [(ActionRunLinkRequest, AppURLRoutingError)] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in },
            actionRejectionHandler: { request, error in
                rejections.append((request, error))
            }
        )
        let url = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/run"))
        var recursiveResult: AppURLHandlingResult?
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { _, _ in
                recursiveResult = router.handle(url)
                return .completed
            }
        )

        XCTAssertEqual(
            router.handle(url),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "run")))
        )
        await router.waitUntilIdle()

        XCTAssertEqual(recursiveResult, .rejected(.recursiveActionInvocation))
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(
            rejections.first?.0,
            .direct(ActionKey(providerID: "test-provider", actionID: "run"))
        )
        XCTAssertEqual(rejections.first?.1, .recursiveActionInvocation)
    }

    func testAliasesShareCanonicalActiveExecutionIdentity() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let presetID = UUID(uuidString: "7B420000-0000-4000-8000-000000000001")!
        let direct = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/continuing")
        )
        let preset = try XCTUnwrap(
            URL(string: "mactools://app/presets/\(presetID.uuidString)")
        )
        let canonical = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "continuing")
        )
        var duplicateResult: AppURLHandlingResult?
        var completion: Task<Void, Never>?
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { _ in .success(canonical) },
            actionHandler: { _, _ in
                let task = Task<Void, Never> {
                    try? await Task.sleep(for: .seconds(60))
                }
                completion = task
                duplicateResult = router.handle(preset)
                return .continuing(until: task)
            }
        )

        XCTAssertEqual(
            router.handle(direct),
            .queuedAction(.direct(canonical.key))
        )
        await router.waitUntilIdle()
        completion?.cancel()
        XCTAssertEqual(duplicateResult, .rejected(.recursiveActionInvocation))
    }

    func testQueuedPresetUsesOneFreshResolutionForGuardAndDispatch() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let presetID = UUID(uuidString: "7B420000-0000-4000-8000-000000000002")!
        let blocker = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/blocker")
        )
        let preset = try XCTUnwrap(
            URL(string: "mactools://app/presets/\(presetID.uuidString)")
        )
        let secondDirect = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/second")
        )
        let firstReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "first")
        )
        let secondReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "second")
        )
        let blockerReference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "blocker")
        )
        var presetReference = firstReference
        var dispatchedPresetReference: ActionReference?
        var recursiveResult: AppURLHandlingResult?

        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { request in
                switch request {
                case let .direct(key):
                    return .success(ActionReference(key: key))
                case .preset:
                    return .success(presetReference)
                }
            },
            actionHandler: { request, resolution in
                guard case .preset = request,
                      case let .success(reference)? = resolution else {
                    return .completed
                }
                dispatchedPresetReference = reference
                recursiveResult = router.handle(secondDirect)
                return .completed
            }
        )

        XCTAssertEqual(router.handle(blocker), .queuedAction(.direct(blockerReference.key)))
        XCTAssertEqual(router.handle(preset), .queuedAction(.preset(presetID)))
        presetReference = secondReference
        await router.waitUntilIdle()

        XCTAssertEqual(dispatchedPresetReference, secondReference)
        XCTAssertEqual(recursiveResult, .rejected(.recursiveActionInvocation))
    }

    func testMutuallyRecursiveActionsAreRejectedUsingQueueAncestry() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let first = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/first"))
        let second = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/second"))
        var nestedResults: [AppURLHandlingResult] = []
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { request, _ in
                switch request {
                case let .direct(key) where key.providerID == "test-provider"
                    && key.actionID == "first":
                    await Task.detached {
                        await MainActor.run {
                            nestedResults.append(router.handle(second))
                        }
                    }.value
                case let .direct(key) where key.providerID == "test-provider"
                    && key.actionID == "second":
                    await Task.detached {
                        await MainActor.run {
                            nestedResults.append(router.handle(first))
                        }
                    }.value
                default:
                    break
                }
                return .completed
            }
        )

        _ = router.handle(first)
        await router.waitUntilIdle()

        XCTAssertEqual(
            nestedResults,
            [
                .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "second"))),
                .rejected(.recursiveActionInvocation),
            ]
        )
    }

    func testHandedOffActionRejectsDuplicateAsAlreadyRunningWithoutBlockingNavigation() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/continuing")
        )
        let settings = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        var requests: [AppPresentationRequest] = []
        var duplicateResult: AppURLHandlingResult?
        var continuingTask: Task<Void, Never>?
        var executionCompletion: Task<Void, Never>?
        router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { _, _ in
                let completion = Task<Void, Never> {
                    try? await Task.sleep(for: .seconds(60))
                }
                executionCompletion = completion
                continuingTask = Task.detached {
                    await MainActor.run {
                        duplicateResult = router.handle(action)
                    }
                }
                return .continuing(until: completion)
            }
        )

        XCTAssertEqual(
            router.handle(action),
            .queuedAction(
                .direct(ActionKey(providerID: "test-provider", actionID: "continuing"))
            )
        )
        await router.waitUntilIdle()

        XCTAssertEqual(router.handle(settings), .handled(.settings(.general)))
        await continuingTask?.value
        executionCompletion?.cancel()
        XCTAssertEqual(requests, [.settings(.general)])
        XCTAssertEqual(duplicateResult, .rejected(.actionAlreadyRunning))
    }

    func testOverlappingIndependentContinuingActionsDoNotInheritEachOthersAncestry() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let first = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/first")
        )
        let second = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/second")
        )
        var completions: [Task<Void, Never>] = []
        var handledActionIDs: [String] = []
        var nestedSecondResult: AppURLHandlingResult?
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { request, _ in
                guard case let .direct(key) = request else { return .completed }
                handledActionIDs.append(key.actionID)
                if key.actionID == "first" && handledActionIDs.count == 1 {
                    nestedSecondResult = router.handle(second)
                }
                let completion = Task<Void, Never> {
                    try? await Task.sleep(for: .seconds(60))
                }
                completions.append(completion)
                return .continuing(until: completion)
            }
        )

        XCTAssertEqual(
            router.handle(first),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "first")))
        )
        await router.waitUntilIdle()
        XCTAssertEqual(
            nestedSecondResult,
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "second")))
        )
        XCTAssertEqual(handledActionIDs, ["first", "second"])

        completions[0].cancel()
        await completions[0].value
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(
            router.handle(first),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "first")))
        )
        await router.waitUntilIdle()
        XCTAssertEqual(handledActionIDs, ["first", "second", "first"])

        for completion in completions.dropFirst() {
            completion.cancel()
            await completion.value
        }
    }
}
