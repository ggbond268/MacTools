import Foundation
import MacToolsPluginKit

enum ActivityBarConstants {
    static let pluginID = "activity-bar"
    static let defaultSocketPath = ActivityBarNamespace().socketPath
}

struct ActivityBarNamespace {
    private let isNightly: Bool

    init(releaseChannel: String? = Bundle.main.object(forInfoDictionaryKey: "MTReleaseChannel") as? String) {
        isNightly = releaseChannel == "nightly"
    }

    var socketPath: String {
        isNightly ? "/tmp/mactools-nightly-activity-bar.sock" : "/tmp/mactools-activity-bar.sock"
    }

    var fallbackHooksDirectory: String {
        isNightly ? ".mactools-nightly/activity-bar/hooks" : ".mactools/activity-bar/hooks"
    }

    func hookFileName(tool: String) -> String {
        // Do not contain the old full filename: older Stable releases remove hooks by that substring.
        "\(isNightly ? "mactools-nightly" : "mactools")-activity-\(tool)-hook.sh"
    }
}

enum ActivityBarInputEvent: Equatable, Sendable {
    case keystroke(app: String)
    case pointerClick(app: String)
    case scroll(app: String)
    case screenTime(app: String, seconds: TimeInterval)
}

enum ActivityBarInputMonitorStatus: Equatable, Sendable {
    case idle
    case running
    case inputMonitoringDenied
}

struct ActivityBarAppStats: Codable, Equatable, Sendable {
    var keystrokes: Int = 0
    var pointerClicks: Int = 0
    var scrollEvents: Int = 0
    var screenTimeSeconds: TimeInterval = 0

    var totalInputs: Int {
        keystrokes + pointerClicks + scrollEvents
    }
}

struct ActivityBarDailyStats: Codable, Identifiable, Equatable, Sendable {
    let date: String
    var keystrokes: Int = 0
    var pointerClicks: Int = 0
    var scrollEvents: Int = 0
    var screenTimeSeconds: TimeInterval = 0
    var perApp: [String: ActivityBarAppStats] = [:]

    var id: String { date }

    var totalInputs: Int {
        keystrokes + pointerClicks + scrollEvents
    }

    var topApps: [(name: String, stats: ActivityBarAppStats)] {
        perApp
            .filter { !$0.key.isEmpty && $0.key != "loginwindow" }
            .map { (name: $0.key, stats: $0.value) }
            .sorted {
                if $0.stats.screenTimeSeconds == $1.stats.screenTimeSeconds {
                    return $0.stats.totalInputs > $1.stats.totalInputs
                }
                return $0.stats.screenTimeSeconds > $1.stats.screenTimeSeconds
            }
    }
}

enum ActivityBarHookEventType: String, Codable, Equatable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case permissionRequest = "PermissionRequest"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ActivityBarHookEventType(rawValue: rawValue) ?? .unknown
    }
}

enum ActivityBarHookStatus: String, Codable, Equatable, Sendable {
    case processing
    case compacting
    case waitingForInput = "waiting_for_input"
    case ended
    case runningTool = "running_tool"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ActivityBarHookStatus(rawValue: rawValue) ?? .unknown
    }
}

struct ActivityBarHookEvent: Codable, Equatable, Sendable {
    let sessionID: String
    let cwd: String?
    let event: ActivityBarHookEventType
    let status: ActivityBarHookStatus
    let userPrompt: String?
    let tool: String?
    let interactive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case event
        case status
        case userPrompt = "user_prompt"
        case tool
        case interactive
    }
}

struct ActivityBarProjectStats: Codable, Equatable, Sendable {
    var durationSeconds: TimeInterval = 0
    var wordCount: Int = 0
    var toolCallCount: Int = 0
}

enum ActivityBarCodingTool: String, CaseIterable, Codable, Equatable, Sendable {
    case claudeCode = "Claude Code"
    case cursor = "Cursor"
    case codex = "Codex"

    static func displayName(forSessionID sessionID: String) -> String {
        if sessionID.hasPrefix("cursor-") {
            return cursor.rawValue
        }

        if sessionID.hasPrefix("codex-") {
            return codex.rawValue
        }

        return claudeCode.rawValue
    }
}

struct ActivityBarCodingDailyStats: Codable, Identifiable, Equatable, Sendable {
    let date: String
    var durationSeconds: TimeInterval = 0
    var wordCount: Int = 0
    var toolCallCount: Int = 0
    var perProject: [String: ActivityBarProjectStats] = [:]
    var perTool: [String: ActivityBarProjectStats] = [:]

    init(
        date: String,
        durationSeconds: TimeInterval = 0,
        wordCount: Int = 0,
        toolCallCount: Int = 0,
        perProject: [String: ActivityBarProjectStats] = [:],
        perTool: [String: ActivityBarProjectStats] = [:]
    ) {
        self.date = date
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.toolCallCount = toolCallCount
        self.perProject = perProject
        self.perTool = perTool
    }

    var id: String { date }

    var topProjects: [(name: String, stats: ActivityBarProjectStats)] {
        perProject
            .map { (name: $0.key, stats: $0.value) }
            .sorted {
                if $0.stats.durationSeconds == $1.stats.durationSeconds {
                    return $0.stats.wordCount > $1.stats.wordCount
                }
                return $0.stats.durationSeconds > $1.stats.durationSeconds
            }
    }

    var topTools: [(name: String, stats: ActivityBarProjectStats)] {
        let knownTools = ActivityBarCodingTool.allCases.map(\.rawValue)
        let knownRows = knownTools.compactMap { name -> (name: String, stats: ActivityBarProjectStats)? in
            guard let stats = perTool[name], stats.durationSeconds > 0 || stats.wordCount > 0 || stats.toolCallCount > 0 else {
                return nil
            }
            return (name: name, stats: stats)
        }

        let customRows = perTool
            .filter { !knownTools.contains($0.key) }
            .map { (name: $0.key, stats: $0.value) }
            .sorted {
                if $0.stats.durationSeconds == $1.stats.durationSeconds {
                    return $0.stats.wordCount > $1.stats.wordCount
                }
                return $0.stats.durationSeconds > $1.stats.durationSeconds
            }

        return knownRows + customRows
    }

    enum CodingKeys: String, CodingKey {
        case date
        case durationSeconds
        case wordCount
        case toolCallCount
        case perProject
        case perTool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        durationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds) ?? 0
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        toolCallCount = try container.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
        perProject = try container.decodeIfPresent([String: ActivityBarProjectStats].self, forKey: .perProject) ?? [:]
        perTool = try container.decodeIfPresent([String: ActivityBarProjectStats].self, forKey: .perTool) ?? [:]
    }
}

enum ActivityBarFormatting {
    static func monthDay(_ date: Date, locale: Locale = PluginRuntimeLocalization.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = PluginRuntimeLocalization.locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func count(_ value: Int) -> String {
        if value >= 10_000 {
            return "\(value / 1_000)k"
        }
        return "\(value)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}
