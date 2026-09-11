import Foundation
import Security

struct CLIPeerIdentity: Equatable {
    let processIdentifier: pid_t
    let effectiveUserIdentifier: uid_t
    let signingIdentifier: String
    let teamIdentifier: String
}

struct CLILocalPeerIdentityCache {
    private var cachedIdentity: CLIPeerIdentity?

    mutating func resolve(
        using loader: () -> CLIPeerIdentity?
    ) -> CLIPeerIdentity? {
        if let cachedIdentity { return cachedIdentity }
        guard let identity = loader() else { return nil }
        cachedIdentity = identity
        return identity
    }
}

enum CLIPeerRole {
    case host
    case commandLineTool
    case broker
}

enum CLIHostIdentityAssessment: Equatable {
    case accepted
    case invalidSignature
    case wrongTeam
    case wrongRole
}

struct CLIPeerIdentityValidator {
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
        applicationIdentityAssessment(
            at: applicationURL,
            as: role,
            relativeTo: currentIdentity
        ) == .accepted
    }

    func applicationIdentityAssessment(
        at applicationURL: URL,
        as role: CLIPeerRole,
        relativeTo currentIdentity: CLIPeerIdentity? = nil
    ) -> CLIHostIdentityAssessment {
        guard let currentIdentity = currentIdentity ?? self.currentIdentity() else {
            return .invalidSignature
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              let metadata = signingMetadata(for: staticCode)
        else {
            return .invalidSignature
        }
        guard metadata.teamIdentifier == currentIdentity.teamIdentifier else { return .wrongTeam }
        guard metadata.signingIdentifier == expectedSigningIdentifier(
            for: role,
            brokerIdentifier: currentIdentity.signingIdentifier
        ) else { return .wrongRole }
        guard let requirement = codeRequirement(
            signingIdentifier: metadata.signingIdentifier,
            teamIdentifier: metadata.teamIdentifier
        ),
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  requirement
              ) == errSecSuccess else {
            return .invalidSignature
        }
        return .accepted
    }

    func accepts(
        _ connection: NSXPCConnection,
        as role: CLIPeerRole,
        brokerIdentity: CLIPeerIdentity? = nil
    ) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(),
              let brokerIdentity = brokerIdentity ?? currentIdentity()
        else { return false }
        let signingIdentifier = expectedSigningIdentifier(
            for: role,
            brokerIdentifier: brokerIdentity.signingIdentifier
        )
        guard let identity = identity(
            processIdentifier: connection.processIdentifier,
            effectiveUserIdentifier: connection.effectiveUserIdentifier,
            expectedSigningIdentifier: signingIdentifier,
            expectedTeamIdentifier: brokerIdentity.teamIdentifier
        ) else { return false }
        return matches(identity, as: role, relativeTo: brokerIdentity)
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
            return false
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
        effectiveUserIdentifier: uid_t,
        expectedSigningIdentifier: String? = nil,
        expectedTeamIdentifier: String? = nil
    ) -> CLIPeerIdentity? {
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              let metadata = signingMetadata(for: staticCode),
              let requirement = codeRequirement(
                  signingIdentifier: expectedSigningIdentifier ?? metadata.signingIdentifier,
                  teamIdentifier: expectedTeamIdentifier ?? metadata.teamIdentifier
              ),
              SecCodeCheckValidity(
                  code,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess else { return nil }

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

    func requirementString(signingIdentifier: String, teamIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(escapedRequirementValue(signingIdentifier))\" "
            + "and certificate leaf[subject.OU] = \"\(escapedRequirementValue(teamIdentifier))\""
    }

    private func codeRequirement(
        signingIdentifier: String,
        teamIdentifier: String
    ) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementString(
                signingIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier
            ) as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        return status == errSecSuccess ? requirement : nil
    }

    private func escapedRequirementValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
