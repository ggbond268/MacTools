import Foundation

struct DiskCleanSafetyPolicy: Sendable {
    let homeDirectory: String
    let whitelistStore: DiskCleanWhitelistStore

    init(
        homeDirectory: String = NSHomeDirectory(),
        whitelistStore: DiskCleanWhitelistStore? = nil
    ) {
        self.homeDirectory = Self.normalizeSlashes(homeDirectory)
        self.whitelistStore = whitelistStore ?? DiskCleanWhitelistStore(homeDirectory: homeDirectory)
    }

    func validatePathShape(
        _ path: String,
        isSymlink: Bool = false,
        resolvedSymlinkTarget: String? = nil
    ) -> DiskCleanSafetyStatus {
        let normalizedPath = normalizePath(path)
        guard !normalizedPath.isEmpty else {
            return .invalid(reason: "empty path")
        }
        guard normalizedPath.hasPrefix("/") else {
            return .invalid(reason: "path must be absolute")
        }
        guard !Self.containsTraversalComponent(normalizedPath) else {
            return .invalid(reason: "path traversal is not allowed")
        }
        guard !Self.containsControlCharacter(normalizedPath) else {
            return .invalid(reason: "path contains control characters")
        }

        if isSymlink {
            guard let resolvedSymlinkTarget, !resolvedSymlinkTarget.isEmpty else {
                return .invalid(reason: "cannot validate symlink target")
            }

            let normalizedTarget = normalizePath(resolvedSymlinkTarget)
            if Self.isProtectedSystemRoot(normalizedTarget) {
                return .invalid(reason: "symlink points to protected system path")
            }
        }

        if Self.isProtectedSystemRoot(normalizedPath) {
            return .invalid(reason: "critical system path")
        }

        return .allowed
    }

    func safetyStatus(
        for path: String,
        isSymlink: Bool = false,
        resolvedSymlinkTarget: String? = nil
    ) -> DiskCleanSafetyStatus {
        let normalizedPath = normalizePath(path)
        let shapeStatus = validatePathShape(
            normalizedPath,
            isSymlink: isSymlink,
            resolvedSymlinkTarget: resolvedSymlinkTarget
        )
        guard case .allowed = shapeStatus else {
            return shapeStatus
        }

        if let reason = sensitiveProtectionReason(for: normalizedPath) {
            return .protected(reason: reason)
        }

        if let rule = whitelistStore.matchingRule(for: normalizedPath) {
            return .whitelisted(rule: rule.expandedPattern)
        }

        return .allowed
    }

    private func normalizePath(_ path: String) -> String {
        let expanded = expandHome(in: path.trimmingCharacters(in: .whitespacesAndNewlines))
        return Self.normalizeSlashes(Self.stripTrailingSlash(expanded))
    }

    private func expandHome(in path: String) -> String {
        if path == "~" || path == "$HOME" || path == "${HOME}" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst())
        }
        if path.hasPrefix("$HOME/") {
            return homeDirectory + String(path.dropFirst("$HOME".count))
        }
        if path.hasPrefix("${HOME}/") {
            return homeDirectory + String(path.dropFirst("${HOME}".count))
        }
        return path
    }

    private func sensitiveProtectionReason(for path: String) -> String? {
        let lower = path.lowercased()

        if Self.hasPathFragment(lower, "/library/keychains")
            || Self.hasPathFragment(lower, "/.ssh")
            || Self.hasPathFragment(lower, "/.gnupg")
            || lower.contains("keychain")
            || lower.contains("credential")
            || lower.contains("auth_token")
            || lower.contains("access_token") {
            return "credentials and key material are protected"
        }

        if Self.hasPathFragment(lower, "/library/application support/com.apple.tcc")
            || lower.hasSuffix("/tcc.db")
            || lower.contains("/tcc/") {
            return "privacy permission database is protected"
        }

        if Self.hasPathFragment(lower, "/library/mobile documents")
            || Self.hasPathFragment(lower, "/mobile documents") {
            return "iCloud synced data is protected"
        }

        if isProtectedBrowserProfileData(lower) {
            return "browser profile data is protected"
        }

        if isProtectedPasswordManagerData(lower) {
            return "password manager data is protected"
        }

        if isProtectedProxyOrVPNData(lower) {
            return "VPN and proxy data is protected"
        }

        if isProtectedSystemState(lower) {
            return "macOS state data is protected"
        }

        if Self.hasPathFragment(lower, "/library/logs/mole")
            || Self.hasPathFragment(lower, "/library/logs/mactools")
            || Self.hasPathFragment(lower, "/.config/mole")
            || Self.hasPathFragment(lower, "/library/application support/mactools") {
            return "cleanup tool state is protected"
        }

        return nil
    }

    private func isProtectedBrowserProfileData(_ lower: String) -> Bool {
        if Self.hasPathFragment(lower, "/library/cookies")
            || lower.hasSuffix(".binarycookies")
            || lower.hasSuffix("/cookies")
            || lower.hasSuffix("/cookies-journal")
            || lower.hasSuffix("/history")
            || lower.hasSuffix("/history-journal")
            || lower.hasSuffix("/login data")
            || lower.hasSuffix("/login data-journal")
            || lower.hasSuffix("/web data")
            || lower.hasSuffix("/local state")
            || lower.hasSuffix("/bookmarks")
            || lower.hasSuffix("/sessions")
            || lower.hasSuffix("/session storage") {
            return true
        }

        if Self.hasPathFragment(lower, "/library/safari")
            && (lower.hasSuffix("/history.db")
                || lower.hasSuffix("/downloads.plist")
                || lower.hasSuffix("/bookmarks.plist")
                || lower.hasSuffix("/lastsession.plist")) {
            return true
        }

        if Self.hasPathFragment(lower, "/library/application support/firefox/profiles")
            && (lower.hasSuffix("/places.sqlite")
                || lower.hasSuffix("/cookies.sqlite")
                || lower.hasSuffix("/key4.db")
                || lower.hasSuffix("/logins.json")
                || lower.contains("/sessionstore")) {
            return true
        }

        return false
    }

    private func isProtectedPasswordManagerData(_ lower: String) -> Bool {
        let tokens = [
            "1password",
            "agilebits",
            "lastpass",
            "dashlane",
            "bitwarden",
            "keepass",
            "keepassxc",
            "authy",
            "yubico"
        ]
        return tokens.contains { lower.contains($0) }
    }

    private func isProtectedProxyOrVPNData(_ lower: String) -> Bool {
        let tokens = [
            "nssurge",
            "surge-mac",
            "clash",
            "mihomo",
            "v2ray",
            "shadowsocks",
            "sing-box",
            "openvpn",
            "tailscale",
            "zerotier",
            "nordvpn",
            "expressvpn",
            "protonvpn",
            "surfshark",
            "windscribe",
            "mullvad",
            "privateinternetaccess",
            "quantumult"
        ]
        return tokens.contains { lower.contains($0) }
    }

    private func isProtectedSystemState(_ lower: String) -> Bool {
        if lower.contains("systemsettings")
            || lower.contains("systempreferences")
            || lower.contains("controlcenter")
            || lower.contains("com.apple.settings")
            || lower.contains("com.apple.notes")
            || lower.contains("com.apple.finder")
            || lower.contains("com.apple.dock")
            || lower.contains("com.apple.bluetooth")
            || lower.contains("com.apple.wifi")
            || lower.contains("org.cups.") {
            return true
        }

        if lower.hasSuffix("/library/preferences/com.apple.dock.plist")
            || lower.hasSuffix("/library/preferences/com.apple.finder.plist") {
            return true
        }

        if lower.contains("inputmethod")
            || lower.contains("textinput")
            || lower.contains("keyboard")
            || lower.contains("inputsource")
            || lower.contains("keylayout")
            || lower.contains("globalpreferences")
            || lower.contains("karabiner") {
            return true
        }

        return false
    }

    private static func containsTraversalComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func containsControlCharacter(_ path: String) -> Bool {
        path.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 127
        }
    }

    private static func isProtectedSystemRoot(_ path: String) -> Bool {
        let normalized = stripTrailingSlash(normalizeSlashes(path))
        if normalized == "/" {
            return true
        }

        let exactRoots = [
            "/private",
            "/var",
            "/var/db",
            "/private/var",
            "/private/var/db"
        ]
        if exactRoots.contains(normalized) {
            return true
        }

        let protectedPrefixes = [
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/etc",
            "/private/etc",
            "/Library/Extensions"
        ]

        return protectedPrefixes.contains { root in
            normalized == root || normalized.hasPrefix(root + "/")
        } || normalized.hasPrefix("/var/db/")
            || normalized.hasPrefix("/private/var/db/")
    }

    private static func hasPathFragment(_ lowerPath: String, _ fragment: String) -> Bool {
        lowerPath == fragment || lowerPath.contains(fragment + "/") || lowerPath.contains(fragment)
    }

    private static func normalizeSlashes(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
