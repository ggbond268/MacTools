import Foundation

struct MoleBackedUninstallReviewService: UninstallReviewProviding, Sendable {
    let scanner: UninstallScanner
    let environment: any UninstallEnvironmentChecking
    let engine: any MoleEnginePlanning

    func installedApplications() async throws -> UninstallInventory {
        let native = UninstallReviewService(scanner: scanner, environment: environment)
        return try await native.installedApplications()
    }

    func review(_ path: String) async throws -> UninstallScan {
        let selected = try scanner.application(path)
        let plan = try await engine.plan(applicationPath: path)
        try Task.checkCancellation()
        guard plan.application.path == selected.path,
              plan.application.bundleID.caseInsensitiveCompare(selected.bundleID) == .orderedSame
        else { throw MoleEngineError.incompatible }

        let state = try await environment.inspect(applicationPath: path)
        try Task.checkCancellation()
        let inventory = try scanner.inventory(runningPaths: state.runningPaths, includeComponents: true)
        var application = selected
        var source = selected.source
        var restrictions = selected.restrictions
        var vendorUninstallers = selected.vendorUninstallers

        switch plan.source {
        case "homebrew":
            source = .homebrew
            restrictions.append("由 Homebrew 管理，请前往 Homebrew 插件卸载。")
        case "vendor":
            source = .vendorRequired
            restrictions.append(plan.blockedReason ?? "请使用开发者提供的卸载工具。")
        case "manual":
            source = .vendorRequired
            restrictions.append(plan.blockedReason ?? "此应用需要手动处理。")
        default:
            break
        }
        if state.isManaged {
            source = .managed
            restrictions.append(contentsOf: state.restrictions)
        } else {
            // Launch-service restrictions are selected-app evidence. Broad process
            // and scan coverage stays visible below without blocking app-only plans.
            restrictions.append(contentsOf: state.restrictions.filter { $0.contains("启动服务") })
        }
        if plan.requiresSudo {
            restrictions.append("此版本仅支持无需管理员权限的废纸篓移除。")
        }
        if let blocked = plan.blockedReason, plan.status != "ready", !restrictions.contains(blocked) {
            restrictions.append(blocked)
        }
        if plan.source == "vendor", let blocked = plan.blockedReason { vendorUninstallers.append(blocked) }

        application = .init(path: selected.path, bundleID: selected.bundleID, name: selected.name,
                            version: selected.version, build: selected.build, executable: selected.executable,
                            teamID: selected.teamID, groups: selected.groups,
                            signingMetadataAvailable: selected.signingMetadataAvailable,
                            identity: selected.identity, metadataDigest: selected.metadataDigest,
                            source: source, restrictions: Array(Set(restrictions)).sorted(),
                            vendorUninstallers: vendorUninstallers)

        let competitors = inventory.apps.filter {
            $0.path != application.path
                && $0.bundleID.caseInsensitiveCompare(application.bundleID) == .orderedSame
        }
        var coverage = inventory.coverage + state.coverage
        coverage.append(contentsOf: plan.warnings.map { .init(path: "Mole", issue: $0) })
        var candidates: [UninstallCandidate] = []
        var seenPaths = Set<String>()
        for engineCandidate in plan.candidates {
            try Task.checkCancellation()
            guard seenPaths.insert(engineCandidate.path).inserted else { continue }
            guard let kind = dataClass(for: engineCandidate.path, application: application) else {
                if engineCandidate.reviewOnly {
                    coverage.append(.init(path: engineCandidate.path,
                                          issue: "Mole found a review-only item outside the first-release removal scope."))
                }
                continue
            }
            var confidence: UninstallConfidence = kind == .application ? .verified : .strong
            var evidence = evidence(for: kind, bundleID: application.bundleID)
            var blocked: String?
            if engineCandidate.reviewOnly {
                confidence = .protected
                blocked = "Mole marked this item as review-only."
            }
            if !competitors.isEmpty, kind != .application {
                confidence = .protected
                evidence += competitors.map { .competingApplication($0.path) }
                blocked = "另一个已安装的应用使用相同标识符。"
            }
            if !inventory.complete, kind != .application {
                blocked = "已安装应用检查不完整，归属仍需核实。"
            }
            if !scanner.configuration.permitted(engineCandidate.path, kind: kind, app: application) {
                confidence = .protected
                blocked = "此位置不在首版允许的移除范围内。"
            }
            var snapshot: UninstallTreeSnapshot?
            do {
                snapshot = try scanner.fileSystem.tree(engineCandidate.path, isApplication: kind == .application)
            } catch {
                try Task.checkCancellation()
                if !UninstallFileSystem.isAbsent(error) {
                    blocked = "大小或路径检查不完整。"
                    coverage.append(.init(path: engineCandidate.path, issue: blocked))
                }
            }
            candidates.append(.init(path: engineCandidate.path, dataClass: kind,
                                    confidence: confidence, evidence: evidence,
                                    snapshot: snapshot, blockedReason: blocked))
        }

        guard candidates.contains(where: { $0.path == application.path && $0.dataClass == .application }) else {
            throw MoleEngineError.incompatible
        }
        let current = try scanner.application(path)
        guard current.identity == selected.identity, current.metadataDigest == selected.metadataDigest else {
            throw AppUninstallerError.changed
        }
        return .init(id: UUID(), observedAt: Date(), application: application,
                     candidates: candidates, coverage: coverage,
                     inventory: inventory.apps, inventoryComplete: inventory.complete,
                     sourceChecksComplete: plan.status == "ready",
                     runningPaths: Array(Set(state.runningPaths + state.activeExecutables)).sorted())
    }

    private func dataClass(for path: String, application: UninstallApplication) -> UninstallDataClass? {
        if path == application.path { return .application }
        for (folder, kind, suffix) in scanner.configuration.roots {
            let expected = scanner.configuration.home + "/Library/" + folder + "/" + application.bundleID + suffix
            if path == expected { return kind }
        }
        return nil
    }

    private func evidence(for kind: UninstallDataClass, bundleID: String) -> [UninstallEvidence] {
        switch kind {
        case .application: [.selectedApplication]
        case .preference: [.preferenceDomain(bundleID)]
        case .savedState: [.savedState(bundleID)]
        case .container: [.exactIdentifier(bundleID)]
        default: [.exactIdentifier(bundleID)]
        }
    }
}
