import Foundation
import MacToolsPluginKit

struct ActivityBarHookInstallSummary: Equatable, Sendable {
    let scriptDirectory: URL
    let installedTools: [String]
}

struct ActivityBarHookUninstallSummary: Equatable, Sendable {
    let scriptDirectory: URL
    let removedTools: [String]
}

struct ActivityBarHookInstallerPaths: Equatable, Sendable {
    let hookScriptsDirectory: URL
    let claudeSettingsPath: URL
    let cursorHooksPath: URL
    let codexConfigPath: URL
    let codexHooksPath: URL

    init(homeDirectory: URL, hookScriptsDirectory: URL? = nil, namespace: ActivityBarNamespace = .init()) {
        self.hookScriptsDirectory = hookScriptsDirectory
            ?? homeDirectory.appendingPathComponent(namespace.fallbackHooksDirectory)
        self.claudeSettingsPath = homeDirectory.appendingPathComponent(".claude/settings.json")
        self.cursorHooksPath = homeDirectory.appendingPathComponent(".cursor/hooks.json")
        self.codexConfigPath = homeDirectory.appendingPathComponent(".codex/config.toml")
        self.codexHooksPath = homeDirectory.appendingPathComponent(".codex/hooks.json")
    }

    static func defaults(
        supportDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        namespace: ActivityBarNamespace = .init()
    ) -> ActivityBarHookInstallerPaths {
        ActivityBarHookInstallerPaths(
            homeDirectory: homeDirectory,
            hookScriptsDirectory: supportDirectory?.appendingPathComponent("hooks"),
            namespace: namespace
        )
    }
}

enum ActivityBarHookInstallerError: LocalizedError, Equatable {
    case invalidJSON(URL)

    var errorDescription: String? {
        localizedDescription(localization: PluginLocalization(bundle: .main))
    }

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case let .invalidJSON(url):
            return localization.format("error.hook.invalidJSON", defaultValue: "无法解析配置文件：%@", url.path)
        }
    }
}

struct ActivityBarHookInstaller {
    private struct FileNames {
        let claude: String
        let cursor: String
        let codex: String

        init(namespace: ActivityBarNamespace) {
            claude = namespace.hookFileName(tool: "claude")
            cursor = namespace.hookFileName(tool: "cursor")
            codex = namespace.hookFileName(tool: "codex")
        }
    }

    private let fileNames: FileNames
    private let paths: ActivityBarHookInstallerPaths
    private let socketPath: String
    private let fileManager: FileManager

    init(
        paths: ActivityBarHookInstallerPaths,
        socketPath: String? = nil,
        namespace: ActivityBarNamespace = .init(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.socketPath = socketPath ?? namespace.socketPath
        self.fileNames = FileNames(namespace: namespace)
        self.fileManager = fileManager
    }

    func install() throws -> ActivityBarHookInstallSummary {
        try installScript(fileName: fileNames.claude, content: claudeHookScript)
        try installScript(fileName: fileNames.cursor, content: cursorHookScript)
        try installScript(fileName: fileNames.codex, content: codexHookScript)

        try registerClaudeHooks()
        try registerCursorHooks()
        try enableCodexHooksFeature()
        try registerCodexHooks()

        return ActivityBarHookInstallSummary(
            scriptDirectory: paths.hookScriptsDirectory,
            installedTools: ["Claude Code", "Cursor", "Codex"]
        )
    }

    func uninstall() throws -> ActivityBarHookUninstallSummary {
        try unregisterClaudeHooks()
        try unregisterCursorHooks()
        try unregisterCodexHooks()
        try removeInstalledScripts()

        return ActivityBarHookUninstallSummary(
            scriptDirectory: paths.hookScriptsDirectory,
            removedTools: ["Claude Code", "Cursor", "Codex"]
        )
    }

    private var claudeScriptURL: URL {
        paths.hookScriptsDirectory.appendingPathComponent(fileNames.claude)
    }

    private var cursorScriptURL: URL {
        paths.hookScriptsDirectory.appendingPathComponent(fileNames.cursor)
    }

    private var codexScriptURL: URL {
        paths.hookScriptsDirectory.appendingPathComponent(fileNames.codex)
    }

    private func installScript(fileName: String, content: String) throws {
        try fileManager.createDirectory(
            at: paths.hookScriptsDirectory,
            withIntermediateDirectories: true
        )

        let scriptURL = paths.hookScriptsDirectory.appendingPathComponent(fileName)
        let existingContent = try? String(contentsOf: scriptURL, encoding: .utf8)
        if existingContent != content {
            try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private func registerClaudeHooks() throws {
        let events = [
            "PreToolUse", "PostToolUse", "UserPromptSubmit",
            "Stop", "SubagentStop", "PreCompact",
            "SessionStart", "SessionEnd", "PermissionRequest",
        ]
        var settings = try readJSONObject(at: paths.claudeSettingsPath)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command: [String: Any] = [
            "type": "command",
            "command": shellQuoted(claudeScriptURL.path),
            "timeout": 5000,
        ]
        var needsWrite = false

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyRegistered = groups.contains { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return groupHooks.contains { hook in
                    containsHookCommand(hook["command"], scriptFileName: fileNames.claude)
                }
            }

            if !alreadyRegistered {
                groups.append([
                    "matcher": "",
                    "hooks": [command],
                ])
                hooks[event] = groups
                needsWrite = true
            }
        }

        guard needsWrite else {
            return
        }

        settings["hooks"] = hooks
        try writeJSONObject(settings, to: paths.claudeSettingsPath)
    }

    private func unregisterClaudeHooks() throws {
        try unregisterGroupedHooks(at: paths.claudeSettingsPath, scriptFileName: fileNames.claude)
    }

    private func registerCursorHooks() throws {
        let events = [
            "beforeSubmitPrompt", "stop", "afterFileEdit",
            "beforeReadFile", "beforeShellExecution", "beforeMCPExecution",
        ]
        var root = try readJSONObject(at: paths.cursorHooksPath)
        if root["version"] == nil {
            root["version"] = 1
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var needsWrite = false

        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyRegistered = entries.contains { entry in
                containsHookCommand(entry["command"], scriptFileName: fileNames.cursor)
            }

            if !alreadyRegistered {
                entries.append([
                    "command": "\(shellQuoted(cursorScriptURL.path)) \(event)",
                ])
                hooks[event] = entries
                needsWrite = true
            }
        }

        guard needsWrite else {
            return
        }

        root["hooks"] = hooks
        try writeJSONObject(root, to: paths.cursorHooksPath)
    }

    private func unregisterCursorHooks() throws {
        guard fileManager.fileExists(atPath: paths.cursorHooksPath.path) else {
            return
        }

        var root = try readJSONObject(at: paths.cursorHooksPath)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var needsWrite = false

        for event in Array(hooks.keys) {
            guard let entries = hooks[event] as? [[String: Any]] else {
                continue
            }

            let filteredEntries = entries.filter { entry in
                !containsHookCommand(entry["command"], scriptFileName: fileNames.cursor)
            }

            guard filteredEntries.count != entries.count else {
                continue
            }

            if filteredEntries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filteredEntries
            }
            needsWrite = true
        }

        guard needsWrite else {
            return
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeJSONObject(root, to: paths.cursorHooksPath)
    }

    private func enableCodexHooksFeature() throws {
        try createParentDirectory(for: paths.codexConfigPath)

        var config = ""
        if fileManager.fileExists(atPath: paths.codexConfigPath.path) {
            config = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        }

        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var updatedLines = lines
        var foundCodexHooks = false

        for index in updatedLines.indices {
            if updatedLines[index].trimmingCharacters(in: .whitespaces).hasPrefix("codex_hooks") {
                updatedLines[index] = "codex_hooks = true"
                foundCodexHooks = true
            }
        }

        if !foundCodexHooks {
            if let featuresIndex = updatedLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
                updatedLines.insert("codex_hooks = true", at: featuresIndex + 1)
            } else {
                if !updatedLines.isEmpty, updatedLines.last != "" {
                    updatedLines.append("")
                }
                updatedLines.append("[features]")
                updatedLines.append("codex_hooks = true")
            }
        }

        var updated = updatedLines.joined(separator: "\n")
        if !updated.hasSuffix("\n") {
            updated += "\n"
        }
        if updated != config {
            try updated.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)
        }
    }

    private func registerCodexHooks() throws {
        let events = [
            "PreToolUse", "PostToolUse", "UserPromptSubmit",
            "Stop", "SessionStart", "SessionEnd",
        ]
        var root = try readJSONObject(at: paths.codexHooksPath)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command: [String: Any] = [
            "type": "command",
            "command": shellQuoted(codexScriptURL.path),
            "timeout": 5000,
        ]
        var needsWrite = false

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyRegistered = groups.contains { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return groupHooks.contains { hook in
                    containsHookCommand(hook["command"], scriptFileName: fileNames.codex)
                }
            }

            if !alreadyRegistered {
                groups.append([
                    "matcher": "",
                    "hooks": [command],
                ])
                hooks[event] = groups
                needsWrite = true
            }
        }

        guard needsWrite else {
            return
        }

        root["hooks"] = hooks
        try writeJSONObject(root, to: paths.codexHooksPath)
    }

    private func unregisterCodexHooks() throws {
        try unregisterGroupedHooks(at: paths.codexHooksPath, scriptFileName: fileNames.codex)
    }

    private func unregisterGroupedHooks(at url: URL, scriptFileName: String) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        var root = try readJSONObject(at: url)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var needsWrite = false

        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else {
                continue
            }

            var updatedGroups: [[String: Any]] = []

            for group in groups {
                guard let groupHooks = group["hooks"] as? [[String: Any]] else {
                    updatedGroups.append(group)
                    continue
                }

                let filteredHooks = groupHooks.filter { hook in
                    !containsHookCommand(hook["command"], scriptFileName: scriptFileName)
                }

                if filteredHooks.count != groupHooks.count {
                    needsWrite = true
                }

                guard !filteredHooks.isEmpty else {
                    continue
                }

                var updatedGroup = group
                updatedGroup["hooks"] = filteredHooks
                updatedGroups.append(updatedGroup)
            }

            if updatedGroups.isEmpty {
                hooks.removeValue(forKey: event)
                needsWrite = true
            } else {
                hooks[event] = updatedGroups
            }
        }

        guard needsWrite else {
            return
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeJSONObject(root, to: url)
    }

    private func removeInstalledScripts() throws {
        for scriptURL in [claudeScriptURL, cursorScriptURL, codexScriptURL] {
            guard fileManager.fileExists(atPath: scriptURL.path) else {
                continue
            }

            try fileManager.removeItem(at: scriptURL)
        }

        guard
            fileManager.fileExists(atPath: paths.hookScriptsDirectory.path),
            (try? fileManager.contentsOfDirectory(atPath: paths.hookScriptsDirectory.path).isEmpty) == true
        else {
            return
        }

        try? fileManager.removeItem(at: paths.hookScriptsDirectory)
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActivityBarHookInstallerError.invalidJSON(url)
        }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try createParentDirectory(for: url)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func createParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func containsHookCommand(_ value: Any?, scriptFileName: String) -> Bool {
        guard let command = value as? String else { return false }
        let ownedCommand = shellQuoted(paths.hookScriptsDirectory.appendingPathComponent(scriptFileName).path)
        return command == ownedCommand || command.hasPrefix(ownedCommand + " ")
    }
}

private extension ActivityBarHookInstaller {
    var claudeHookScript: String {
        """
        #!/bin/bash
        # MacTools Activity Bar hook for Claude Code.

        SOCKET_PATH="\(socketPath)"
        [ -S "$SOCKET_PATH" ] || exit 0

        IS_INTERACTIVE=true
        for CHECK_PID in $PPID $(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' '); do
            if ps -o args= -p "$CHECK_PID" 2>/dev/null | grep -qE '(^| )(-p|--print)( |$)'; then
                IS_INTERACTIVE=false
                break
            fi
        done
        export MACTOOLS_ACTIVITY_INTERACTIVE=$IS_INTERACTIVE

        /usr/bin/python3 -c '
        import json
        import os
        import socket
        import sys

        socket_path = sys.argv[1]
        try:
            input_data = json.load(sys.stdin)
        except Exception:
            sys.exit(0)

        hook_event = input_data.get("hook_event_name", "")
        status_map = {
            "UserPromptSubmit": "processing",
            "PreCompact": "compacting",
            "SessionStart": "waiting_for_input",
            "SessionEnd": "ended",
            "PreToolUse": "running_tool",
            "PostToolUse": "processing",
            "PermissionRequest": "waiting_for_input",
            "Stop": "waiting_for_input",
            "SubagentStop": "waiting_for_input",
        }
        output = {
            "session_id": input_data.get("session_id", ""),
            "cwd": input_data.get("cwd", ""),
            "event": hook_event,
            "status": input_data.get("status", status_map.get(hook_event, "unknown")),
            "interactive": os.environ.get("MACTOOLS_ACTIVITY_INTERACTIVE", "true") == "true",
        }
        if hook_event == "UserPromptSubmit" and input_data.get("prompt"):
            output["user_prompt"] = input_data.get("prompt")
        if input_data.get("tool_name"):
            output["tool"] = input_data.get("tool_name")
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(socket_path)
            sock.sendall(json.dumps(output).encode())
            sock.close()
        except Exception:
            pass
        ' "$SOCKET_PATH"
        """
    }

    var cursorHookScript: String {
        """
        #!/bin/bash
        # MacTools Activity Bar hook for Cursor.

        SOCKET_PATH="\(socketPath)"
        [ -S "$SOCKET_PATH" ] || { cat > /dev/null 2>&1; exit 0; }
        EVENT_TYPE="$1"
        SESSION_ID="cursor-$(echo "${PWD}-$(date +%Y-%m-%d)" | shasum | cut -c1-12)"

        /usr/bin/python3 -c '
        import json
        import os
        import socket
        import sys

        socket_path = sys.argv[1]
        event_type = sys.argv[2] if len(sys.argv) > 2 else ""
        session_id = sys.argv[3] if len(sys.argv) > 3 else "cursor"
        event_map = {
            "beforeSubmitPrompt": "UserPromptSubmit",
            "afterFileEdit": "PostToolUse",
            "stop": "Stop",
            "beforeReadFile": "PreToolUse",
            "beforeShellExecution": "PreToolUse",
            "beforeMCPExecution": "PreToolUse",
        }
        mapped_event = event_map.get(event_type)
        if not mapped_event:
            sys.exit(0)
        status_map = {
            "UserPromptSubmit": "processing",
            "PostToolUse": "processing",
            "Stop": "waiting_for_input",
            "PreToolUse": "running_tool",
        }
        output = {
            "session_id": session_id,
            "cwd": os.getcwd(),
            "event": mapped_event,
            "status": status_map.get(mapped_event, "unknown"),
            "interactive": True,
        }
        try:
            input_data = json.load(sys.stdin)
            if isinstance(input_data, dict):
                for key in ("prompt", "message", "content", "text", "query"):
                    if isinstance(input_data.get(key), str):
                        output["user_prompt"] = input_data[key]
                        break
                if input_data.get("filePath"):
                    output["tool"] = "Read"
                if input_data.get("command"):
                    output["tool"] = "Bash"
        except Exception:
            pass
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(socket_path)
            sock.sendall(json.dumps(output).encode())
            sock.close()
        except Exception:
            pass
        ' "$SOCKET_PATH" "$EVENT_TYPE" "$SESSION_ID"
        """
    }

    var codexHookScript: String {
        """
        #!/bin/bash
        # MacTools Activity Bar hook for Codex.

        SOCKET_PATH="\(socketPath)"
        [ -S "$SOCKET_PATH" ] || exit 0

        /usr/bin/python3 -c '
        import json
        import socket
        import sys

        socket_path = sys.argv[1]
        try:
            input_data = json.load(sys.stdin)
        except Exception:
            sys.exit(0)

        hook_event = input_data.get("hook_event_name", "")
        session_id = input_data.get("session_id", "")
        if session_id and not session_id.startswith("codex-"):
            session_id = "codex-" + session_id
        status_map = {
            "UserPromptSubmit": "processing",
            "SessionStart": "waiting_for_input",
            "SessionEnd": "ended",
            "PreToolUse": "running_tool",
            "PostToolUse": "processing",
            "Stop": "waiting_for_input",
        }
        output = {
            "session_id": session_id,
            "cwd": input_data.get("cwd", ""),
            "event": hook_event,
            "status": status_map.get(hook_event, "unknown"),
            "interactive": True,
        }
        if hook_event == "UserPromptSubmit" and input_data.get("prompt"):
            output["user_prompt"] = input_data.get("prompt")
        if input_data.get("tool_name"):
            output["tool"] = input_data.get("tool_name")
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(socket_path)
            sock.sendall(json.dumps(output).encode())
            sock.close()
        except Exception:
            pass
        ' "$SOCKET_PATH"
        """
    }
}
