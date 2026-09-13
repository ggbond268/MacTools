# AI Usage

AI Usage (`ai-usage`) is a PluginKit v6 plugin for MacTools 1.3.1 or later. It provides a Dashboard component and a declarative settings form, with no Feature Panel entry. The first version supports one current Codex login and one current Claude Code login.

## Setup

1. Sign in to Codex or Claude Code with a subscription account in the corresponding client.
2. Enable **AI Usage** and add its component to Dashboard.
3. Enable **Read local login files** for file-based logins, or **Read Claude Code Keychain** for a Keychain login. These access switches are independent of each other and of service visibility. Enabling Keychain access may show a macOS authorization prompt; background reads never prompt.
4. In **AI Services**, each service has one row with an **Open Website** button followed by its display switch. Enable the services to query and display. Hiding a service does not revoke its access permissions.
5. Optionally enable the single menu-bar switch. Every enabled service appears together; left-click opens the host Dashboard and right-click opens plugin settings.

The Dashboard opens directly with service cards, using the shared System Status theme palette for percentages and progress bars while preserving the original monochrome provider icons. Settings and manual refresh remain in the plugin settings page. Each service uses a two-column grid: **remaining** percentages and window labels are centered on the left, with equal-width progress bars and reset countdowns centered on the right. The primary window is emphasized above the compact weekly reading. The menu bar pairs each enabled provider's logo with that same primary remaining percentage. An orange indicator appears only for retained stale quota readings. Hovering explains that the previous reading is being shown and includes its update time. Current and unavailable readings have no status dot. A dash means no reading is available. Dimmed values and a tooltip identify stale readings. Values are not combined across services, and missing windows are not reported as zero. A reset countdown reaching zero waits for a fresh server reading instead of assuming the quota has reset.

## Quota pace

Each service can show a compact pace label in its header. Windows are identified by their explicit duration, regardless of the provider's primary or secondary slot. A seven-day window takes priority and shows **Weekly on pace**, **Weekly pace high**, or **Weekly exhausted**. Accounts with only a five-hour window use **5h on pace**, **5h pace high**, or **5h exhausted**. When both windows exist, both quota rows remain visible and the header describes weekly pace. Missing durations are not inferred. Localized hover text explains each state in plain language: normal consumption, faster consumption that could exhaust the quota before reset, or an exhausted quota awaiting reset.

The model compares the used percentage with elapsed time at the snapshot's observation time, using the provider's reset timestamp and the selected window's duration. Consumption more than five percentage points ahead of elapsed time is marked high; consumption at or above 100% is marked exhausted, including near reset. All other valid readings are on pace, including early in the cycle. For example, 5% used with about 3% of the week elapsed is on pace. The five-point tolerance absorbs small differences and does not represent a forecast or real-time burn rate.

Labels are hidden for unavailable or stale readings, after reset, for future observations, and when the selected cycle is ambiguous or its percentages or timing are invalid. They are recalculated from existing snapshots; no additional requests, persisted history, timers, or credential access are introduced. An orange stale-data dot replaces the pace label when a retained reading becomes stale.

## Data access

- Codex: read-only `~/.codex/auth.json`, or `auth.json` inside an absolute `CODEX_HOME` inherited by MacTools. Subscription OAuth and personal access tokens are accepted; ordinary API keys are not subscription quotas.
- Claude Code: read-only `~/.claude/.credentials.json`, or `.credentials.json` inside an absolute `CLAUDE_CONFIG_DIR` inherited by MacTools. When file access is off or the file is absent, independently authorized access to the `Claude Code-credentials` Keychain item is available.
- Requests go only to `chatgpt.com/backend-api/wham/usage` and `api.anthropic.com/api/oauth/usage`. Web dashboard buttons open the provider's usage page in the default browser.
- No conversation scanning, token-cost estimates, browser-cookie extraction, credential writes, token refresh, telemetry, or third-party dependencies are included.
- Only settings are persisted. Tokens and quota readings are not cached on disk. Revoking a data source clears affected readings; any independently authorized source remains available. Disabling a service clears its readings but preserves its permissions. Server rate-limit delays survive these changes.
- No Accessibility, Screen Recording, or Full Disk Access permission is required. Keychain authorization is a data-source setting, not a fabricated macOS TCC permission card.

The endpoints are provider client interfaces and may change. Unsupported or malformed responses produce an explicit unavailable state. Expired or denied credentials require signing in again in the original client, then refreshing. Keychain-only Codex logins and custom Claude Keychain service names are not supported in this version.

## Refresh and performance

The default interval is five minutes, with two-, fifteen-, and thirty-minute options. A single tolerant timer checks due work every thirty seconds. Requests for the two providers run concurrently, repeated refreshes coalesce, and manual refreshes have a sixty-second minimum interval. Rate limits wait at least ten minutes and respect longer `Retry-After` values up to one day. Other failures back off up to thirty minutes. Manual refresh cannot bypass an active rate-limit delay.

The host activity lifecycle cancels requests and stops the timer while locked, asleep, or waking. Interactive activity resumes due work. Panel and settings getters only read snapshots. Countdown rendering updates once a minute while the Dashboard component is visible. Provider logos are loaded once; the menu-bar controller redraws only when displayed values or freshness change. Credential files and responses have size bounds, requests use an ephemeral session without cookies or caching, and redirects are refused.

Network failures retain the last successful reading with a warning. Changed credential identities and authentication failures clear the prior reading so another account's quota cannot be presented as current.

## Development and verification

```sh
make generate
make build-plugin PLUGIN=AIUsage
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/AIUsageParserTests \
  -only-testing:MacToolsTests/AIUsageViewModelTests \
  -only-testing:MacToolsTests/AIUsagePaceTests
make script-tests
```

The tests use fake clients, temporary credential files, and an in-memory settings store. Rendering tests write synthetic light, dark, English, exhausted, stale, empty-state, service-row, and menu-bar previews under `MacToolsAIUsageQA/` in the system temporary directory. No test reads real credentials or contacts a quota endpoint. Validate a real account manually after enabling data access in settings.

## References

- [cc-bar](https://github.com/nanvon/cc-bar): reference for quota windows, native presentation, and credential-source behavior.
- [cc-bar Codex client](https://github.com/nanvon/cc-bar/blob/main/Core/Quota/CodexQuotaClient.swift) and [Claude client](https://github.com/nanvon/cc-bar/blob/main/Core/Quota/ClaudeQuotaClient.swift): endpoint and response-format verification, including Claude's generic and legacy windows.
- [CodexBar](https://github.com/steipete/CodexBar): reference for compact provider usage and reset-time presentation.

MacTools implements its own narrowly scoped provider clients and uses its existing component theme, settings renderer, and host Dashboard routing.

Provider logo SVG assets come from cc-bar revision `812f556f58b9e3d9e7a822feba4f74e450517caf`. Their MIT license is retained in the central third-party inventory and included in the plugin package notices.
