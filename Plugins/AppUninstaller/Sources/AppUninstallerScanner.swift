import CryptoKit
import Foundation
import Security

struct UninstallConfiguration: Sendable {
    let home: String
    let applicationRoots: [String]
    let selfPath: String
    let selfBundleID: String
    let caskRoots: [String]

    static func system() -> Self {
        let home = UninstallFileSystem.physicalHome(NSHomeDirectory())
        return Self(home: home, applicationRoots: ["/Applications", home + "/Applications", "/System/Applications"],
                    selfPath: Bundle.main.bundleURL.path, selfBundleID: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
                    caskRoots: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"])
    }

    var roots: [(String, UninstallDataClass, String)] {
        [("Caches", .cache, ""), ("Logs", .log, ""), ("Preferences", .preference, ".plist"),
         ("Saved Application State", .savedState, ".savedState"), ("Application Support", .support, ""),
         ("Containers", .container, ""), ("Group Containers", .groupContainer, "")]
    }

    func permitted(_ path: String, kind: UninstallDataClass, app: UninstallApplication) -> Bool {
        if kind == .application {
            return path == app.path && applicationRoots.prefix(2).contains { UninstallPaths.contains(path, in: $0) && path != $0 }
                && !path.split(separator: "/").dropLast().contains { $0.lowercased().hasSuffix(".app") }
        }
        return roots.contains { folder, dataClass, suffix in
            dataClass == kind && path == home + "/Library/" + folder + "/" + app.bundleID + suffix
                && kind != .groupContainer
        }
    }
}

struct UninstallInventory: Sendable {
    let apps: [UninstallApplication]
    let coverage: [UninstallCoverage]
    var complete: Bool { coverage.allSatisfy { $0.issue == nil } }
}

struct UninstallScanner: Sendable {
    let configuration: UninstallConfiguration
    var fileSystem = UninstallFileSystem()

    func application(_ path: String) throws -> UninstallApplication {
        guard path.lowercased().hasSuffix(".app") else { throw AppUninstallerError.invalidApplication }
        let before = try fileSystem.identity(at: path)
        guard before.isDirectory else { throw AppUninstallerError.invalidApplication }
        let data = try fileSystem.read(path + "/Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, UninstallPaths.validIdentifier(identifier),
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, UninstallPaths.component(executable),
              try fileSystem.identity(at: path + "/Contents/MacOS/" + executable).isRegular else {
            throw AppUninstallerError.invalidApplication
        }
        var restrictions: [String] = []
        var source: UninstallSource = .unknown
        if UninstallPaths.contains(path, in: "/System") || identifier.lowercased().hasPrefix("com.apple.") {
            source = .system; restrictions.append("系统应用受保护。")
        }
        if path == configuration.selfPath || identifier == configuration.selfBundleID || identifier.lowercased().contains("mactools") {
            restrictions.append("MacTools 及其数据受保护。")
        }
        if path.split(separator: "/").dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
            restrictions.append("嵌入式应用应由所属应用管理。")
        }
        if !(configuration.applicationRoots.prefix(2).contains { UninstallPaths.contains(path, in: $0) && path != $0 }) {
            restrictions.append("此应用位于常用安装目录之外。")
        }
        if (info["SMPrivilegedExecutables"] as? [String: Any])?.isEmpty == false {
            source = .vendorRequired; restrictions.append("包含特权辅助工具，请使用开发者提供的卸载方式。")
        }
        for folder in ["Library/SystemExtensions", "Library/DriverExtensions", "Library/LaunchDaemons", "Library/LaunchAgents"] {
            do {
                if !(try fileSystem.children(path + "/Contents/" + folder)).isEmpty {
                    source = .vendorRequired; restrictions.append("包含系统组件，请使用开发者提供的卸载方式。")
                }
            } catch {
                try Task.checkCancellation(); if !UninstallFileSystem.isAbsent(error) { restrictions.append("无法检查应用内的系统组件。") } }
        }
        do {
            if try fileSystem.identity(at: path + "/Contents/_MASReceipt/receipt").isRegular, source == .unknown {
                source = .appStoreReceipt
            }
        } catch {
                try Task.checkCancellation(); if !UninstallFileSystem.isAbsent(error) { restrictions.append("无法检查安装收据。") } }
        let signing = signingMetadata(path)
        guard try fileSystem.identity(at: path) == before,
              try fileSystem.read(path + "/Contents/Info.plist") == data else { throw AppUninstallerError.changed }
        return UninstallApplication(path: path, bundleID: identifier,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            version: info["CFBundleShortVersionString"] as? String ?? "—", build: info["CFBundleVersion"] as? String ?? "—",
            executable: path + "/Contents/MacOS/" + executable, teamID: signing.0, groups: signing.1, signingMetadataAvailable: signing.2,
            identity: before, metadataDigest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            source: source, restrictions: restrictions)
    }

    /// Signature fields are evidence only after validation; unsigned apps still have a readable bundle identity.
    private func signingMetadata(_ path: String) -> (String?, [String], Bool) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil) == errSecSuccess else { return (nil, [], false) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return (nil, [], false) }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = (entitlements?["com.apple.security.application-groups"] as? [String] ?? []).filter(UninstallPaths.validIdentifier)
        return (info[kSecCodeInfoTeamIdentifier as String] as? String, groups.sorted(), true)
    }

    func inventory(runningPaths: [String]) throws -> UninstallInventory {
        var apps: [UninstallApplication] = []
        var coverage: [UninstallCoverage] = []
        var visited = Set<String>()
        var count = 0
        let started = Date()
        func walk(_ path: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 6, count < 10_000, Date().timeIntervalSince(started) < 30 else { throw AppUninstallerError.incomplete }
            guard visited.insert(path).inserted else { return }
            count += 1
            if path.lowercased().hasSuffix(".app") {
                apps.append(try application(path))
                for subroot in ["Contents/Library/LoginItems", "Contents/Helpers"] {
                    do { try walk(path + "/" + subroot, depth: depth + 1) }
                    catch { try Task.checkCancellation(); if !UninstallFileSystem.isAbsent(error) { coverage.append(.init(path: path + "/" + subroot, issue: "嵌入式应用检查不完整。")) } }
                }
                return
            }
            for name in try fileSystem.children(path, limit: 10_000) {
                try Task.checkCancellation()
                let child = path + "/" + name
                do {
                    if try fileSystem.identity(at: child).isDirectory { try walk(child, depth: depth + 1) }
                } catch {
                try Task.checkCancellation()
                    coverage.append(.init(path: child, issue: "此位置未完成应用身份检查。"))
                }
            }
        }
        for root in configuration.applicationRoots {
            do {
                try walk(root, depth: 0)
                coverage.append(.init(path: root, issue: nil))
            } catch {
                try Task.checkCancellation()
                if UninstallFileSystem.isAbsent(error), root == configuration.home + "/Applications" {
                    coverage.append(.init(path: root, issue: nil))
                } else { coverage.append(.init(path: root, issue: "应用目录无法完整读取。")) }
            }
        }
        for path in runningPaths where !visited.contains(path) {
            do { apps.append(try application(path)) }
            catch { try Task.checkCancellation(); coverage.append(.init(path: path, issue: "运行中的应用身份无法读取。")) }
        }
        return UninstallInventory(apps: apps.sorted { $0.path < $1.path }, coverage: coverage)
    }

    func scan(path: String, environment: UninstallEnvironmentSnapshot) throws -> UninstallScan {
        let selected = try application(path)
        let inventory = try inventory(runningPaths: environment.runningPaths)
        var app = selected
        var restrictions = selected.restrictions + environment.restrictions
        var source = selected.source
        let siblings = inventory.apps.filter {
            $0.path != selected.path && URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == URL(fileURLWithPath: selected.path).deletingLastPathComponent().path
                && $0.name.localizedCaseInsensitiveContains("uninstall") && selected.teamID != nil && $0.teamID == selected.teamID
        }.map(\.path)
        var vendorUninstallers = siblings
        for folder in ["Contents", "Contents/Resources"] {
            do {
                for name in try fileSystem.children(path + "/" + folder, limit: 5_000) where name.localizedCaseInsensitiveContains("uninstall") {
                    let item = path + "/" + folder + "/" + name
                    _ = try fileSystem.identity(at: item)
                    vendorUninstallers.append(item)
                }
            } catch {
                try Task.checkCancellation()
                if !fileSystem.isMissingCandidate(path + "/" + folder, error: error) { restrictions.append("无法完整检查应用自带的卸载工具。") }
            }
        }
        if !vendorUninstallers.isEmpty {
            source = .vendorRequired
            restrictions.append("发现可能的厂商卸载工具，请先检查其说明。")
        }
        if environment.isManaged { source = .managed }
        if environment.homebrewApps.contains(where: { $0.lowercased() == path.lowercased() }) {
            source = .homebrew; restrictions.append("由 Homebrew 管理，请前往 Homebrew 插件卸载。")
        }
        app = .init(path: selected.path, bundleID: selected.bundleID, name: selected.name, version: selected.version, build: selected.build,
                    executable: selected.executable, teamID: selected.teamID, groups: selected.groups, signingMetadataAvailable: selected.signingMetadataAvailable, identity: selected.identity,
                    metadataDigest: selected.metadataDigest, source: source, restrictions: restrictions, vendorUninstallers: vendorUninstallers)
        let competitors = inventory.apps.filter { $0.bundleID.lowercased() == app.bundleID.lowercased() && $0.path != app.path }
        var coverage = inventory.coverage + environment.coverage
        var candidates: [UninstallCandidate] = []
        func candidate(_ path: String, kind: UninstallDataClass, evidence initial: [UninstallEvidence], confidence initialConfidence: UninstallConfidence) throws {
            var evidence = initial
            var confidence = initialConfidence
            var blocked: String?
            if !competitors.isEmpty && kind != .application {
                confidence = .protected
                evidence += competitors.map { .competingApplication($0.path) }
                blocked = "另一个已安装的应用使用相同标识符。"
            }
            if !inventory.complete { blocked = "已安装应用检查不完整，归属仍需核实。" }
            if !app.restrictions.isEmpty { blocked = app.restrictions.joined(separator: " ") }
            if !configuration.permitted(path, kind: kind, app: app) { blocked = "此位置仅供查看，无法确认独占归属。" }
            var snapshot: UninstallTreeSnapshot?
            do { snapshot = try fileSystem.tree(path) }
            catch {
                try Task.checkCancellation()
                if fileSystem.isMissingCandidate(path, error: error) { return }
                blocked = "大小或路径检查不完整。"
                coverage.append(.init(path: path, issue: blocked))
            }
            if let identity = snapshot?.identity {
                let expectedType = kind == .preference ? identity.isRegular
                    : [.application, .cache, .savedState, .support, .container, .groupContainer].contains(kind) ? identity.isDirectory : true
                if !expectedType {
                    confidence = .protected
                    blocked = "项目类型与此关联规则不一致。"
                }
            }
            if kind == .container, snapshot?.identity.isDirectory == true {
                do {
                    let metadata = try fileSystem.plist(path + "/.com.apple.containermanagerd.metadata.plist")
                    if metadata["MCMMetadataIdentifier"] as? String == app.bundleID {
                        evidence.append(.containerMetadata(app.bundleID)); confidence = competitors.isEmpty ? .verified : .protected
                    } else {
                        evidence.append(.conflictingMetadata); confidence = .protected; blocked = "容器元数据与所选应用不一致。"
                    }
                } catch {
                try Task.checkCancellation(); confidence = .possible; blocked = "无法验证容器的所属应用。" }
            }
            candidates.append(.init(path: path, dataClass: kind, confidence: confidence, evidence: evidence, snapshot: snapshot, blockedReason: blocked))
        }
        try candidate(path, kind: .application, evidence: [.selectedApplication], confidence: .verified)
        for (folder, kind, suffix) in configuration.roots {
            let root = configuration.home + "/Library/" + folder
            do {
                _ = try fileSystem.identity(at: root)
                coverage.append(.init(path: root, issue: kind == .groupContainer && !app.signingMetadataAvailable ? "签名中的共享组信息无法验证，此位置检查不完整。" : nil))
                if kind == .groupContainer {
                    for group in app.groups {
                        try candidate(root + "/" + group, kind: kind, evidence: [.groupEntitlement(group)], confidence: .shared)
                    }
                } else {
                    let evidence: UninstallEvidence = kind == .preference ? .preferenceDomain(app.bundleID)
                        : kind == .savedState ? .savedState(app.bundleID) : .exactIdentifier(app.bundleID)
                    try candidate(root + "/" + app.bundleID + suffix, kind: kind, evidence: [evidence], confidence: .strong)
                }
            } catch {
                try Task.checkCancellation()
                coverage.append(.init(path: root, issue: UninstallFileSystem.isAbsent(error) ? nil : "关联位置无法读取。"))
            }
        }
        guard try application(path).metadataDigest == app.metadataDigest,
              try fileSystem.identity(at: path) == app.identity else { throw AppUninstallerError.changed }
        return UninstallScan(id: UUID(), observedAt: Date(), application: app, candidates: candidates,
                            coverage: coverage, inventory: inventory.apps, inventoryComplete: inventory.complete,
                            sourceChecksComplete: environment.complete, runningPaths: environment.runningPaths)
    }
}
