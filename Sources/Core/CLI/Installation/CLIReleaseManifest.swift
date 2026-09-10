import CryptoKit
import Foundation
import MacToolsCLIProtocol
import Security

enum CLIInstallError: String, Error, LocalizedError {
    case unsupported, metadata, download, archive, signature, notarization, identity, version, incompatible
    case ownership, collision, filesystem, busy, validation

    var errorDescription: String? {
        switch self {
        case .unsupported: AppL10n.settings("cli.install.error.unsupported",
            defaultValue: "仅支持 Apple 芯片 Mac 上的已签名 Nightly 版本。")
        case .metadata: AppL10n.settings("cli.install.error.metadata",
            defaultValue: "此版本缺少有效的 CLI 安装信息，请更新 Nightly 后重试。")
        case .download: AppL10n.settings("cli.install.error.download",
            defaultValue: "CLI 下载失败或超过大小限制，请检查网络后重试。")
        case .archive: AppL10n.settings("cli.install.error.archive",
            defaultValue: "CLI 压缩包校验失败，原有安装未更改。")
        case .signature: AppL10n.settings("cli.install.error.signature",
            defaultValue: "CLI 未通过 macOS 签名检查，请重试或更新 Nightly。")
        case .notarization: AppL10n.settings("cli.install.error.notarization",
            defaultValue: "无法确认 CLI 的公证状态，请检查网络后重试，或更新 Nightly。")
        case .identity: AppL10n.settings("cli.install.error.identity",
            defaultValue: "CLI 与此 Nightly 的发布身份不匹配。")
        case .version: AppL10n.settings("cli.install.error.version",
            defaultValue: "CLI 版本与应用不匹配，请重试。")
        case .incompatible: AppL10n.settings("cli.install.error.incompatible",
            defaultValue: "CLI 协议不兼容，应用操作已被阻止。请更新 CLI；version 命令仍可使用。")
        case .ownership: AppL10n.settings("cli.install.error.ownership",
            defaultValue: "无法确认 CLI 安装归属，已停止更改。请保留文件并检查安装路径。")
        case .collision: AppL10n.settings("cli.install.error.collision",
            defaultValue: "mactools-nightly 路径已被占用，请自行移动现有命令后重试。")
        case .filesystem: AppL10n.settings("cli.install.error.filesystem",
            defaultValue: "无法安全完成 CLI 文件操作，请检查可用空间和目录权限后重试。")
        case .busy: AppL10n.settings("cli.install.error.busy",
            defaultValue: "另一项 CLI 操作正在进行，请稍后重试。")
        case .validation: AppL10n.settings("cli.install.error.validation",
            defaultValue: "CLI 连接验证失败，已尝试恢复上一版本。请检查命令行集成和后台运行权限后重试。")
        }
    }
}

/// This file is sealed inside the Developer ID signed app, never loaded from a network catalog.
struct CLIReleaseManifest: Codable, Equatable, Sendable {
    let schema: Int
    let channel: String
    let appVersion: String
    let appBuild: String
    let cliVersion: String
    let cliBuild: String
    let sourceCommit: String
    let sourceRelease: URL
    let assetURL: URL
    let sha256: String
    let size: Int
    let architecture: String
    let signingIdentifier: String
    let teamIdentifier: String
    let protocolMinimum: Int
    let protocolMaximum: Int

    static let maximumArchiveSize = 64 * 1024 * 1024
    var directoryName: String { "\(cliVersion)-\(cliBuild)-\(sha256.prefix(12))" }
    var isCompatible: Bool {
        protocolMinimum <= CLIProtocolVersion.current && protocolMaximum >= CLIProtocolVersion.minimum
    }

    func validate(version: String, build: String, identifier: String, team: String) throws {
        func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        guard schema == 1, channel == "nightly", architecture == "arm64",
              appVersion == version, appBuild == build, cliVersion == appVersion, cliBuild == appBuild,
              matches(cliVersion, "^[0-9]+(\\.[0-9]+){0,3}$"),
              matches(cliBuild, "^[0-9]+(\\.[0-9]+){0,3}$"),
              matches(sourceCommit, "^[a-f0-9]{40}$"), matches(sha256, "^[a-f0-9]{64}$"),
              size > 0, size <= Self.maximumArchiveSize,
              identifier.hasSuffix(".mactools.nightly"), signingIdentifier == identifier + ".cli",
              teamIdentifier == team, matches(team, "^[A-Z0-9]{10}$"),
              protocolMinimum > 0, protocolMaximum >= protocolMinimum,
              protocolMaximum <= 1000 else { throw CLIInstallError.metadata }
        for url in [sourceRelease, assetURL] {
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.port == nil,
                  !url.absoluteString.contains("%"), !url.pathComponents.contains("..") else {
                throw CLIInstallError.metadata
            }
        }
        // Both channels use immutable versioned release directories, never /latest or /current.
        let releasePath = sourceRelease.path
        let githubRelease = releasePath.hasSuffix("/releases/download/nightly-" + cliBuild.replacingOccurrences(of: ".", with: "-"))
        let localRelease = releasePath == "/releases/" + cliBuild
        guard githubRelease || localRelease,
              assetURL == sourceRelease.appendingPathComponent("mactools-cli-\(cliVersion)-\(cliBuild)-macos-arm64.zip")
        else { throw CLIInstallError.metadata }
        guard isCompatible else { throw CLIInstallError.incompatible }
    }

    static func authenticated(bundle: Bundle = .main) throws -> Self {
        #if arch(arm64)
        guard bundle.object(forInfoDictionaryKey: "MTReleaseChannel") as? String == "nightly",
              let identity = CLIPeerIdentityValidator().currentIdentity(),
              identity.signingIdentifier == bundle.bundleIdentifier else { throw CLIInstallError.unsupported }
        try CLIArtifactVerifier.verifySignature(at: bundle.bundleURL,
            identifier: identity.signingIdentifier, team: identity.teamIdentifier, notarized: false)
        guard let url = bundle.url(forResource: "cli-install", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 16384,
              let manifest = try? JSONDecoder().decode(Self.self, from: data) else { throw CLIInstallError.metadata }
        try manifest.validate(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            identifier: identity.signingIdentifier, team: identity.teamIdentifier)
        return manifest
        #else
        throw CLIInstallError.unsupported
        #endif
    }
}

func cliSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
