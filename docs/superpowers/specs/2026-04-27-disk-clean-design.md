# Disk Clean Design

## Summary

Add a new MacTools plugin named "磁盘清理" that brings the relevant `mo clean`
behavior from Mole into the native MacTools experience. The first version exposes
three user-facing cleanup choices:

- 缓存清理
- 开发者缓存清理
- 浏览器缓存清理

The UI does not expose Mole's internal command-line phases. Internally, MacTools
ports the matching `mo clean` rules, skip conditions, dry-run behavior, whitelist
handling, path safety checks, and sensitive-data protections for those three
cleanup choices.

## Goals

- Provide a native menu-bar entry point for scanning and cleaning reclaimable
  user-level cache data.
- Preserve Mole's mature safety model for the supported cleanup categories.
- Let users choose among the three supported cleanup categories before scanning
  and before cleaning.
- Show an auditable preview: category, item count, size, skipped/protected count,
  and warnings.
- Support built-in and custom whitelist rules.
- Ensure every candidate path passes safety validation before it can be reported
  as cleanable or deleted.

## Non-Goals

The first version does not migrate or expose:

- system-level or sudo-required cleanup
- Time Machine cleanup
- cached device firmware cleanup
- app leftovers and orphaned services cleanup
- System Data hint reporting
- large-file candidate reporting
- project artifact purge
- external-volume cleanup
- app uninstall behavior
- optimize/status/analyze dashboards beyond what is needed for cleanup preview

These can be added later as separate user-facing capabilities after the first
cleanup plugin is stable.

## User Experience

The menu-bar plugin appears as a disclosure row named "磁盘清理". Its subtitle
shows one of these states:

- "选择清理范围" before a scan
- "正在扫描..." while scanning
- "可清理 X GB" after a successful scan
- "无需清理" when no candidates are found
- a concise error message when scanning or cleaning fails

Expanding the plugin shows:

- a segmented or checklist-style control for the three cleanup choices
- a "扫描" action row
- after scanning, a "打开清理详情" action row

The detail window is the main workspace for this feature. It contains:

- summary totals: reclaimable size, item count, protected/skipped count
- one section per selected cleanup choice
- candidate rows with display name, path summary, size, and risk level
- protected/skipped rows collapsed behind a disclosure
- a global whitelist management section
- a primary "清理所选项目" action

The UI must make preview mandatory. Cleaning can only run against the latest
scan result. If the selected cleanup choices or whitelist changes after a scan,
the previous result becomes stale and cleaning is disabled until the user scans
again.

## Cleanup Mapping

### 缓存清理

This category ports user-level cache cleanup from `mo clean`, excluding system
and sudo-required operations. It includes:

- user cache and log cleanup from `clean_user_essentials`
- Finder metadata behavior from `clean_finder_metadata`, respecting Mole's
  `FINDER_METADATA` whitelist sentinel
- sandbox/container app cache behavior from Mole's user cache logic
- desktop app cache rules from Mole's GUI application cache logic
- cloud and office application cache rules that are user-level and cache-only

It excludes app leftovers, orphaned services, device backups, firmware, Time
Machine, large file reporting, and System Data hints.

### 开发者缓存清理

This category ports Mole's developer-tool cleanup rules, including:

- Xcode caches, DerivedData, logs, Products, Archives, Documentation caches
- CoreSimulator caches and temp/log cleanup, with Simulator-running skips
- unavailable simulator device cleanup preview and execution semantics
- npm, pnpm, yarn, bun, pip, Go, Rust, mise, Nix, cloud CLI, frontend build
  caches, mobile tooling, JVM, JetBrains, AI agent/editor caches, shell/network
  tool caches, and Homebrew cache rules that are user-level
- Mole's command-backed cleanup behavior where applicable, with timeouts and
  fallback filesystem cleanup preserved

The first version excludes operations that require sudo or are outside the
selected category boundary.

### 浏览器缓存清理

This category ports Mole's browser cache cleanup rules, including:

- Safari cache
- Chrome, Chromium, Arc, Dia, Brave, Edge, Helium, Yandex, Firefox, Opera,
  Vivaldi, Comet, Orion, Zen, and Puppeteer cache paths
- Service Worker CacheStorage cleanup with Mole's protected-domain behavior
- ScriptCache skip behavior while Chromium-family browsers are running
- Firefox cache/profile cleanup skip behavior while Firefox is running
- old Chromium-family version cleanup rules that Mole applies in browser cleanup

Browser history, cookies, passwords, sessions, bookmarks, and profile data remain
protected and are never cleanup targets.

## Safety Model

MacTools introduces a `CleanSafetyPolicy` that ports Mole's safety decisions
into Swift. All scanner and executor paths must use this policy.

Path validation rejects:

- empty paths
- relative paths
- path traversal components such as `/../`
- control characters and newlines
- critical system roots such as `/`, `/System`, `/bin`, `/sbin`, `/usr`, `/etc`,
  `/private`, `/var`, and `/Library/Extensions`
- symlinks that resolve to protected system paths
- any path matched by sensitive-data protection rules

Sensitive-data protection ports Mole's protected categories for the supported
cleanup scope, including:

- Keychains, password managers, credentials, auth tokens, SSH/GPG data
- TCC, System Settings, Control Center, Dock/Finder critical state
- browser history, cookies, login data, sessions, and profile identity files
- VPN and proxy tools where Mole treats data as protected
- input methods and keyboard/text input state
- AI model and workspace data that Mole protects by default
- iCloud-synced `Mobile Documents`
- Mole/MacTools operation logs and cleanup whitelist files

Every cleanup candidate has a safety status:

- `allowed`: can be selected and cleaned
- `whitelisted`: protected by user or default whitelist
- `protected`: blocked by sensitive-data or system protection
- `invalid`: rejected path shape or unsafe symlink
- `requiresAdmin`: discovered but not supported in this first version
- `inUse`: skipped because the owning app or tool is running

Only `allowed` candidates can be cleaned.

## Whitelist Model

MacTools supports both default and custom whitelist rules.

Default whitelist rules are ported from Mole for the supported cleanup scope,
including Playwright browsers, HuggingFace caches, Maven local repository,
Gradle caches, Ollama models, Surge Mac data, R renv caches, JetBrains caches,
Finder metadata sentinel, FontRegistry, Spotlight, CloudKit, and iCloud-synced
Mobile Documents protections.

Custom whitelist rules are stored in a MacTools-owned settings store. The store
preserves one rule per line semantics and supports:

- absolute paths
- `~` expansion
- `$HOME` and `${HOME}` expansion
- glob-style suffix matching compatible with Mole's cleanup behavior

Custom rules are validated before saving. Invalid rules are rejected with a
specific reason, not silently ignored.

## Architecture

### Plugin Layer

`DiskCleanPlugin` conforms to `FeaturePlugin`. It owns only panel state and
routes panel actions to the controller. It does not scan or delete files itself.

### Controller Layer

`DiskCleanController` is the main state machine:

- selected cleanup choices
- scan state
- scan result
- cleaning state
- stale-result detection
- cancellation
- user-facing errors

The controller exposes snapshot data for plugin state and the detail window.

### Rule Layer

`CleanRuleCatalog` defines the supported cleanup rules. Rules are grouped by the
three user-facing cleanup choices and carry:

- stable rule ID
- display title
- category
- target discovery strategy
- risk level
- app/tool running checks
- command-backed cleanup metadata where needed

Rules should be data-oriented where practical, with dedicated Swift discovery
code only for Mole behaviors that cannot be represented as static paths.

### Scanner Layer

`CleanScanner` runs a dry-run scan. It expands rule targets, checks app/tool
running conditions, validates every path through `CleanSafetyPolicy`, computes
sizes, deduplicates parent/child paths, and returns a structured `CleanScanResult`.

Scanning must be cancellable and must not delete or mutate candidate files.

### Executor Layer

`CleanExecutor` receives a `CleanScanResult` plus selected candidate IDs. It
revalidates every path through `CleanSafetyPolicy` immediately before deletion.
It then executes the cleanup according to the ported Mole rule behavior.

The executor records per-item outcomes:

- removed
- skipped because whitelisted/protected
- skipped because in use
- failed because permission denied
- failed because path changed
- failed because command timed out

The final summary shows reclaimed bytes based on successful removals only.

## Data Flow

1. User selects one or more cleanup choices.
2. User starts scan.
3. Controller creates a scan request with selected choices and current whitelist.
4. Scanner evaluates matching rules and returns structured candidates.
5. UI displays totals and per-category details.
6. User optionally updates selection or whitelist.
7. If whitelist or selected choices change, scan becomes stale.
8. User starts cleaning from a fresh scan result.
9. Executor revalidates candidates and performs cleanup.
10. Controller publishes final result and refreshes plugin subtitle.

## Error Handling

- Permission-denied paths are reported as skipped or failed without aborting the
  whole run.
- A single rule failure does not abort other selected rules.
- A timeout in command-backed cleanup reports the affected rule as timed out.
- If scan or cleanup is canceled, completed results remain visible and the UI
  clearly marks the run as canceled.
- If a candidate path disappears between scan and clean, it is treated as already
  gone and does not count as reclaimed space unless deletion succeeded.
- If Full Disk Access would improve results, the UI shows guidance but does not
  block user-level cleanup.

## Testing Strategy

Unit tests cover:

- path validation parity for empty, relative, traversal, control-character,
  protected-root, and symlink cases
- sensitive-data protection matching for critical Mole categories
- whitelist parsing, expansion, duplicate handling, and invalid-rule rejection
- rule catalog grouping into exactly the three user-facing cleanup choices
- scanner dry-run behavior with fake filesystem fixtures
- scanner deduplication of parent/child candidates
- app-running skip logic for Xcode, Simulator, Firefox, and Chromium-family
  ScriptCache rules
- executor revalidation before deletion
- executor summary accounting for removed, skipped, and failed candidates
- plugin panel state transitions for idle, scanning, scanned, stale, cleaning,
  failed, and canceled states

Integration-style tests use temporary directories and fake command runners so no
test deletes real user data or invokes real sudo.

## Rollout

The first implementation should land behind the new plugin only. Existing
plugins and the current physical clean mode behavior remain unchanged.

Documentation updates should clarify that "清洁模式" is physical clean mode,
while "磁盘清理" is cache cleanup.
