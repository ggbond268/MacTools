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
        let vendorEvidence = try scanner.vendorUninstallerEvidence(for: selected, inventory: inventory)
        var application = selected
        var source = selected.source
        var restrictions = selected.restrictions + vendorEvidence.restrictions
        let vendorUninstallers = vendorEvidence.paths

        if !vendorUninstallers.isEmpty {
            source = .vendorRequired
            restrictions.append("发现可能的厂商卸载工具，请先检查其说明。")
        }

        switch plan.source {
        case "homebrew":
            source = .homebrew
            restrictions.append("由 Homebrew 管理，请前往 Homebrew 插件卸载。")
        case "vendor":
            source = .vendorRequired
            restrictions.append("请使用开发者提供的卸载工具。")
        case "manual":
            source = .vendorRequired
            restrictions.append("此应用需要手动处理。")
        default:
            break
        }
        if state.homebrewApps.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
            source = .homebrew
            restrictions.append("由 Homebrew 管理，请前往 Homebrew 插件卸载。")
        }
        if state.managementState != .unmanaged {
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
        if plan.status != "ready", !["homebrew", "vendor", "manual"].contains(plan.source) {
            restrictions.append("Mole 无法安全准备此应用的移除清单。")
        }

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
        coverage.append(contentsOf: plan.warnings.map { .init(path: "Mole", issue: localizedWarning($0)) })
        var candidates: [UninstallCandidate] = []
        var seenPaths = Set<String>()
        for engineCandidate in plan.candidates {
            try Task.checkCancellation()
            guard seenPaths.insert(engineCandidate.path).inserted else { continue }
            guard let kind = dataClass(for: engineCandidate.path, application: application) else {
                if engineCandidate.reviewOnly {
                    coverage.append(.init(path: engineCandidate.path,
                                          issue: "Mole 发现首版移除范围以外的仅供检查项目。"))
                }
                continue
            }
            let confidence: UninstallConfidence = engineCandidate.reviewOnly ? .protected
                : kind == .application ? .verified : .strong
            let blocked = engineCandidate.reviewOnly ? "Mole 将此项目标记为仅供检查。" : nil
            if let candidate = try scanner.validatedCandidate(
                path: engineCandidate.path,
                kind: kind,
                application: application,
                competitors: competitors,
                inventoryComplete: inventory.complete,
                initialEvidence: evidence(for: kind, bundleID: application.bundleID),
                initialConfidence: confidence,
                initialBlockedReason: blocked,
                coverage: &coverage
            ) {
                candidates.append(candidate)
            }
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
                     sourceChecksComplete: plan.status == "ready" && state.managementState == .unmanaged
                        && state.sourceChecksComplete,
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

    private func localizedWarning(_ warning: String) -> String {
        switch warning {
        case "Another installed copy may share data; Mole narrowed the plan.":
            "另一个已安装副本可能共享数据；Mole 已缩小清单范围。"
        case "System-level remnants are review-only and are not removable by this plan.":
            "系统级残留仅供检查，无法通过此清单移除。"
        default:
            "Mole 报告一项未识别的检查警告；仅显示已验证项目。"
        }
    }
}
