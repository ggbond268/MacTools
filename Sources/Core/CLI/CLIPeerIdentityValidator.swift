import Foundation
import Security

struct CLIPeerIdentity: Equatable {
    let processIdentifier: pid_t
    let effectiveUserIdentifier: uid_t
    let signingIdentifier: String
    let teamIdentifier: String
}

enum CLIPeerRole {
    case host
    case commandLineTool
    case broker
}

struct CLIPeerIdentityValidator {
    private let allowsUnverifiedPeersForTesting: Bool

    init() {
        allowsUnverifiedPeersForTesting = false
    }

    #if DEBUG
    init(allowsUnverifiedPeersForTesting: Bool) {
        self.allowsUnverifiedPeersForTesting = allowsUnverifiedPeersForTesting
    }
    #endif

    func identity(for connection: NSXPCConnection) -> CLIPeerIdentity? {
        identity(
            processIdentifier: connection.processIdentifier,
            effectiveUserIdentifier: connection.effectiveUserIdentifier
        )
    }

    func currentIdentity() -> CLIPeerIdentity? {
        identity(processIdentifier: getpid(), effectiveUserIdentifier: geteuid())
    }

    func acceptsApplication(
        at applicationURL: URL,
        as role: CLIPeerRole,
        relativeTo currentIdentity: CLIPeerIdentity? = nil
    ) -> Bool {
        guard let currentIdentity = currentIdentity ?? self.currentIdentity() else {
            return allowsUnverifiedPeersForTesting
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  nil
              ) == errSecSuccess,
              let metadata = signingMetadata(for: staticCode)
        else {
            return allowsUnverifiedPeersForTesting
        }
        return metadata.teamIdentifier == currentIdentity.teamIdentifier
            && metadata.signingIdentifier == expectedSigningIdentifier(
                for: role,
                brokerIdentifier: currentIdentity.signingIdentifier
            )
    }

    func accepts(
        _ connection: NSXPCConnection,
        as role: CLIPeerRole,
        brokerIdentity: CLIPeerIdentity? = nil
    ) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        if let identity = identity(for: connection),
           let brokerIdentity = brokerIdentity ?? currentIdentity() {
            return matches(identity, as: role, relativeTo: brokerIdentity)
        }
        return allowsUnverifiedPeersForTesting
    }

    func matches(
        _ identity: CLIPeerIdentity,
        as role: CLIPeerRole,
        relativeTo brokerIdentity: CLIPeerIdentity
    ) -> Bool {
        identity.effectiveUserIdentifier == brokerIdentity.effectiveUserIdentifier
            && identity.teamIdentifier == brokerIdentity.teamIdentifier
            && identity.signingIdentifier == expectedSigningIdentifier(
                for: role,
                brokerIdentifier: brokerIdentity.signingIdentifier
            )
    }

    func configure(
        _ connection: NSXPCConnection,
        toRequire role: CLIPeerRole,
        currentIdentity: CLIPeerIdentity? = nil
    ) -> Bool {
        guard let currentIdentity = currentIdentity ?? self.currentIdentity() else {
            return allowsUnverifiedPeersForTesting
        }
        let identifier = expectedSigningIdentifier(
            for: role,
            brokerIdentifier: currentIdentity.signingIdentifier
        )
        let requirement = requirementString(
            signingIdentifier: identifier,
            teamIdentifier: currentIdentity.teamIdentifier
        )
        connection.setCodeSigningRequirement(requirement)
        return true
    }

    func brokerListenerRequirement() -> String? {
        guard let identity = currentIdentity() else { return nil }
        let hostIdentifier = expectedSigningIdentifier(
            for: .host,
            brokerIdentifier: identity.signingIdentifier
        )
        let cliIdentifier = expectedSigningIdentifier(
            for: .commandLineTool,
            brokerIdentifier: identity.signingIdentifier
        )
        let team = escapedRequirementValue(identity.teamIdentifier)
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and "
            + "(identifier \"\(escapedRequirementValue(hostIdentifier))\" or "
            + "identifier \"\(escapedRequirementValue(cliIdentifier))\")"
    }

    func expectedSigningIdentifier(for role: CLIPeerRole, brokerIdentifier: String) -> String {
        let hostIdentifier: String
        if brokerIdentifier.hasSuffix(".cli-broker") {
            hostIdentifier = String(brokerIdentifier.dropLast(".cli-broker".count))
        } else if brokerIdentifier.hasSuffix(".cli") {
            hostIdentifier = String(brokerIdentifier.dropLast(".cli".count))
        } else {
            hostIdentifier = brokerIdentifier
        }
        switch role {
        case .host: return hostIdentifier
        case .commandLineTool: return "\(hostIdentifier).cli"
        case .broker: return "\(hostIdentifier).cli-broker"
        }
    }

    private func identity(
        processIdentifier: pid_t,
        effectiveUserIdentifier: uid_t
    ) -> CLIPeerIdentity? {
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        guard let metadata = signingMetadata(for: staticCode) else { return nil }

        return CLIPeerIdentity(
            processIdentifier: processIdentifier,
            effectiveUserIdentifier: effectiveUserIdentifier,
            signingIdentifier: metadata.signingIdentifier,
            teamIdentifier: metadata.teamIdentifier
        )
    }

    private func signingMetadata(
        for staticCode: SecStaticCode
    ) -> (signingIdentifier: String, teamIdentifier: String)? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
        let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
        !signingIdentifier.isEmpty,
        !teamIdentifier.isEmpty else { return nil }
        return (signingIdentifier, teamIdentifier)
    }

    private func requirementString(signingIdentifier: String, teamIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(escapedRequirementValue(signingIdentifier))\" "
            + "and certificate leaf[subject.OU] = \"\(escapedRequirementValue(teamIdentifier))\""
    }

    private func escapedRequirementValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
