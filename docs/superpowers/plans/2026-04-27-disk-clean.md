# Disk Clean Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native "磁盘清理" plugin that exposes cache cleanup, developer cache cleanup, and browser cache cleanup with Mole-compatible safety, whitelist, dry-run scanning, and execution semantics for those categories.

**Architecture:** Implement the feature as a new plugin backed by focused Swift services: models, whitelist store, safety policy, rule catalog, scanner, executor, controller, and detail UI. Keep file discovery and deletion behind protocols so tests run against temporary fixtures and fake command/process runners.

**Tech Stack:** Swift 6, SwiftUI, AppKit menu-bar window integration, XCTest, Foundation `FileManager`, Darwin `fnmatch` for glob-compatible path matching.

---

## File Structure

- Create `Sources/Features/DiskClean/DiskCleanModels.swift`: shared value types for categories, rules, candidates, scan results, execution results, safety statuses, and controller snapshots.
- Create `Sources/Features/DiskClean/DiskCleanSafetyPolicy.swift`: Mole-compatible path validation, sensitive-data protection, whitelist checks, and risk classification.
- Create `Sources/Features/DiskClean/DiskCleanWhitelistStore.swift`: default/custom whitelist loading, validation, expansion, and persistence.
- Create `Sources/Features/DiskClean/DiskCleanRuleCatalog.swift`: data-oriented port of Mole rules for the three supported cleanup choices.
- Create `Sources/Features/DiskClean/DiskCleanFileSystem.swift`: file-system abstraction, glob expansion, size calculation, and delete wrapper.
- Create `Sources/Features/DiskClean/DiskCleanScanner.swift`: dry-run scanner that expands rules and returns a structured preview.
- Create `Sources/Features/DiskClean/DiskCleanExecutor.swift`: executor that revalidates and removes selected candidates.
- Create `Sources/Features/DiskClean/DiskCleanController.swift`: main state machine for UI snapshots, scan, clean, stale result detection, and cancellation.
- Create `Sources/Features/DiskClean/DiskCleanPlugin.swift`: `FeaturePlugin` implementation.
- Create `Sources/Features/DiskClean/DiskCleanDetailView.swift`: detail window for selection, preview, whitelist, and cleanup.
- Modify `Sources/App/MacToolsApp.swift`: add a `disk-clean` window.
- Modify `Sources/App/MenuBarContent.swift`: route the disk-clean detail action to the new window.
- Modify `Sources/Core/Plugins/PluginHost.swift`: register `DiskCleanPlugin`.
- Modify `README.md`: document physical clean mode vs disk cleanup.
- Create tests under `Tests/Features/DiskClean/`.

## Task 1: Models

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanModels.swift`
- Test: `Tests/Features/DiskClean/DiskCleanModelsTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MacTools

final class DiskCleanModelsTests: XCTestCase {
    func testCleanupChoiceTitlesMatchFirstVersionScope() {
        XCTAssertEqual(DiskCleanChoice.cache.title, "缓存清理")
        XCTAssertEqual(DiskCleanChoice.developer.title, "开发者缓存清理")
        XCTAssertEqual(DiskCleanChoice.browser.title, "浏览器缓存清理")
        XCTAssertEqual(DiskCleanChoice.allCases, [.cache, .developer, .browser])
    }

    func testScanResultTotalsOnlyAllowedCandidates() {
        let result = DiskCleanScanResult(
            choices: [.cache],
            candidates: [
                DiskCleanCandidate(id: "a", ruleID: "r1", choice: .cache, title: "A", path: "/tmp/a", sizeBytes: 10, safety: .allowed, risk: .low),
                DiskCleanCandidate(id: "b", ruleID: "r2", choice: .cache, title: "B", path: "/tmp/b", sizeBytes: 20, safety: .protected(reason: "protected"), risk: .high)
            ],
            scannedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.cleanableSizeBytes, 10)
        XCTAssertEqual(result.cleanableCandidates.map(\.id), ["a"])
        XCTAssertEqual(result.protectedCount, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanModelsTests test`

Expected: FAIL because the `DiskClean*` types do not exist.

- [ ] **Step 3: Implement the models**

Create the public internal model surface used by downstream tasks:

```swift
import Foundation

enum DiskCleanChoice: String, CaseIterable, Identifiable, Equatable {
    case cache
    case developer
    case browser

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cache: return "缓存清理"
        case .developer: return "开发者缓存清理"
        case .browser: return "浏览器缓存清理"
        }
    }
}

enum DiskCleanRisk: Equatable {
    case low
    case medium
    case high
}

enum DiskCleanSafetyStatus: Equatable {
    case allowed
    case whitelisted(rule: String)
    case protected(reason: String)
    case invalid(reason: String)
    case requiresAdmin(reason: String)
    case inUse(processName: String)

    var isCleanable: Bool {
        if case .allowed = self { return true }
        return false
    }
}

struct DiskCleanCandidate: Identifiable, Equatable {
    let id: String
    let ruleID: String
    let choice: DiskCleanChoice
    let title: String
    let path: String
    let sizeBytes: Int64
    let safety: DiskCleanSafetyStatus
    let risk: DiskCleanRisk
}

struct DiskCleanScanResult: Equatable {
    let choices: Set<DiskCleanChoice>
    let candidates: [DiskCleanCandidate]
    let scannedAt: Date

    var cleanableCandidates: [DiskCleanCandidate] {
        candidates.filter { $0.safety.isCleanable }
    }

    var cleanableSizeBytes: Int64 {
        cleanableCandidates.reduce(0) { $0 + max($1.sizeBytes, 0) }
    }

    var protectedCount: Int {
        candidates.filter {
            if case .protected = $0.safety { return true }
            if case .whitelisted = $0.safety { return true }
            return false
        }.count
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanModelsTests test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanModels.swift Tests/Features/DiskClean/DiskCleanModelsTests.swift
git commit -m "feat(clean): add disk clean models"
```

## Task 2: Whitelist Store

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanWhitelistStore.swift`
- Test: `Tests/Features/DiskClean/DiskCleanWhitelistStoreTests.swift`

- [ ] **Step 1: Write failing tests for defaults, expansion, duplicates, and invalid rules**

Tests should verify:

- default rules include Mole-protected entries for Playwright, HuggingFace, Maven, Gradle, Ollama, Surge, R renv, JetBrains, FontRegistry, Spotlight, CloudKit, Mobile Documents, and `FINDER_METADATA`
- `~`, `$HOME`, and `${HOME}` expand to the injected home path
- duplicate rules collapse to one entry
- relative paths, traversal components, control characters, and protected system roots are rejected

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanWhitelistStoreTests test`

Expected: FAIL because `DiskCleanWhitelistStore` does not exist.

- [ ] **Step 3: Implement whitelist store**

Create:

- `DiskCleanWhitelistRule`
- `DiskCleanWhitelistValidationError`
- `DiskCleanWhitelistStore`
- default rule list matching the first-version Mole scope
- `expandedRules(homeDirectory:)`
- `validateCustomRule(_:homeDirectory:)`
- exact and glob-aware path matching using `fnmatch`

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanWhitelistStoreTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanWhitelistStore.swift Tests/Features/DiskClean/DiskCleanWhitelistStoreTests.swift
git commit -m "feat(clean): add whitelist store"
```

## Task 3: Safety Policy

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanSafetyPolicy.swift`
- Test: `Tests/Features/DiskClean/DiskCleanSafetyPolicyTests.swift`

- [ ] **Step 1: Write failing tests**

Tests should cover Mole parity for:

- empty and relative paths rejected
- `/tmp/../etc` rejected
- Firefox-style `name..files` accepted
- control characters rejected
- `/`, `/System`, `/usr/bin`, `/etc`, `/private`, `/var/db`, and `/Library/Extensions` rejected
- allowed user cache path accepted
- whitelisted path reports `.whitelisted`
- sensitive paths under keychains, browser cookies/history, TCC, Mobile Documents, password manager data, and VPN/proxy data report `.protected`

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanSafetyPolicyTests test`

Expected: FAIL because safety policy does not exist.

- [ ] **Step 3: Implement safety policy**

Implement:

- `validatePathShape(_:)`
- `safetyStatus(for:isSymlink:resolvedSymlinkTarget:)`
- sensitive pattern checks ported from Mole's cleanup-protection categories
- whitelist checks before returning `.allowed`
- system-root and safe-user-cache allowlist behavior aligned to the three supported categories

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanSafetyPolicyTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanSafetyPolicy.swift Tests/Features/DiskClean/DiskCleanSafetyPolicyTests.swift
git commit -m "feat(clean): add safety policy"
```

## Task 4: File System and Glob Expansion

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanFileSystem.swift`
- Test: `Tests/Features/DiskClean/DiskCleanFileSystemTests.swift`

- [ ] **Step 1: Write failing tests**

Use temporary directories to verify:

- `~` expansion
- glob expansion for one-level and nested wildcard patterns
- paths with spaces match
- parent/child deduplication keeps the parent only
- size calculation includes nested files
- symlink paths can report link metadata without following protected targets during safety validation

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanFileSystemTests test`

Expected: FAIL because file-system helpers do not exist.

- [ ] **Step 3: Implement file-system helpers**

Implement:

- `DiskCleanFileSystemProviding`
- `LocalDiskCleanFileSystem`
- `expandPathPattern(_:)`
- `sizeOfItem(at:)`
- `removeItem(at:)`
- `deduplicatedParentChildPaths(_:)`

Use Darwin `fnmatch` for shell-style matching. Do not use ad hoc substring matching for glob expansion.

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanFileSystemTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanFileSystem.swift Tests/Features/DiskClean/DiskCleanFileSystemTests.swift
git commit -m "feat(clean): add file scanning helpers"
```

## Task 5: Rule Catalog

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanRuleCatalog.swift`
- Test: `Tests/Features/DiskClean/DiskCleanRuleCatalogTests.swift`

- [ ] **Step 1: Write failing tests**

Tests should verify:

- exactly three choices are exposed
- cache rules contain representative Mole user/app/cloud/office cache paths
- developer rules contain Xcode, Simulator, npm, pnpm, bun, pip, Go, Rust, Docker BuildX, JetBrains, Cursor, Codex, and Homebrew cache rules
- browser rules contain Safari, Chrome, Arc, Brave, Edge, Firefox, Vivaldi, Comet, Orion, Zen, Service Worker, and old-version cleanup rules
- no first-version rule has `.requiresAdmin`

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanRuleCatalogTests test`

Expected: FAIL because the catalog does not exist.

- [ ] **Step 3: Implement rule catalog**

Represent rules as:

```swift
struct DiskCleanRule: Identifiable, Equatable {
    enum Target: Equatable {
        case path(String)
        case dynamic(DiskCleanDynamicRule)
    }

    let id: String
    let choice: DiskCleanChoice
    let title: String
    let risk: DiskCleanRisk
    let targets: [Target]
    let skipWhenProcessIsRunning: [String]
}
```

Port all applicable static path rules from the Mole files covered by the spec.
Use dynamic rules for:

- Xcode DerivedData project counting
- npm/pnpm/bun/pip/go cache-path discovery
- Service Worker protected-domain cleanup
- Chromium-family ScriptCache running-app skip
- Firefox running-app skip
- old browser version cleanup

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanRuleCatalogTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanRuleCatalog.swift Tests/Features/DiskClean/DiskCleanRuleCatalogTests.swift
git commit -m "feat(clean): port clean rule catalog"
```

## Task 6: Scanner

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanScanner.swift`
- Test: `Tests/Features/DiskClean/DiskCleanScannerTests.swift`

- [ ] **Step 1: Write failing tests**

Use fake rule catalogs and fake file systems to verify:

- scanner returns candidates only for selected choices
- dry-run scan never deletes files
- whitelisted and protected paths are present as non-cleanable candidates
- in-use rules are skipped with `.inUse`
- parent/child candidates are deduplicated
- total cleanable size excludes protected and in-use candidates

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanScannerTests test`

Expected: FAIL because scanner does not exist.

- [ ] **Step 3: Implement scanner**

Implement `DiskCleanScanning` with:

- cancellable async `scan(choices:)`
- rule expansion through `DiskCleanFileSystemProviding`
- process-running checks through a small `DiskCleanProcessInspecting` protocol
- safety evaluation through `DiskCleanSafetyPolicy`
- stable candidate IDs generated from rule ID and path

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanScannerTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanScanner.swift Tests/Features/DiskClean/DiskCleanScannerTests.swift
git commit -m "feat(clean): add dry-run scanner"
```

## Task 7: Executor

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanExecutor.swift`
- Test: `Tests/Features/DiskClean/DiskCleanExecutorTests.swift`

- [ ] **Step 1: Write failing tests**

Use fake file systems to verify:

- executor removes only selected `.allowed` candidates
- executor revalidates each path before deletion
- protected, whitelisted, invalid, in-use, and requires-admin candidates are skipped
- missing paths are treated as skipped without aborting
- summary counts removed, skipped, failed, and reclaimed bytes correctly

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanExecutorTests test`

Expected: FAIL because executor does not exist.

- [ ] **Step 3: Implement executor**

Implement:

- `DiskCleanExecutionResult`
- `DiskCleanExecutionItemResult`
- async `clean(candidates:selectedCandidateIDs:)`
- final safety revalidation immediately before delete
- FileManager-backed direct removal to match `mo clean` semantics for supported user-level cache paths

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanExecutorTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanExecutor.swift Tests/Features/DiskClean/DiskCleanExecutorTests.swift
git commit -m "feat(clean): add clean executor"
```

## Task 8: Controller

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanController.swift`
- Test: `Tests/Features/DiskClean/DiskCleanControllerTests.swift`

- [ ] **Step 1: Write failing tests**

Tests should verify:

- idle subtitle is "选择清理范围"
- scan transitions through scanning to scanned
- changing selected choices after scan marks result stale
- cleaning is disabled for stale results
- clean transitions through cleaning to completed
- scanner/executor errors become user-facing error messages
- canceling scan or clean returns to a stable state

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanControllerTests test`

Expected: FAIL because controller does not exist.

- [ ] **Step 3: Implement controller**

Implement `@MainActor final class DiskCleanController: ObservableObject` with:

- `@Published private(set) var snapshot`
- `setChoice(_:isSelected:)`
- `scan()`
- `cleanSelected(candidateIDs:)`
- `cancelCurrentOperation()`
- stale-result tracking

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanControllerTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean/DiskCleanController.swift Tests/Features/DiskClean/DiskCleanControllerTests.swift
git commit -m "feat(clean): add disk clean controller"
```

## Task 9: Plugin and Window UI

**Files:**
- Create: `Sources/Features/DiskClean/DiskCleanPlugin.swift`
- Create: `Sources/Features/DiskClean/DiskCleanDetailView.swift`
- Modify: `Sources/App/MacToolsApp.swift`
- Modify: `Sources/App/MenuBarContent.swift`
- Modify: `Sources/Core/Plugins/PluginHost.swift`
- Test: `Tests/Features/DiskClean/DiskCleanPluginTests.swift`

- [ ] **Step 1: Write failing tests**

Tests should verify:

- plugin manifest ID is `disk-clean`
- plugin title is `磁盘清理`
- plugin exposes three selected cleanup options
- invoking scan forwards to the controller
- invoking open details uses the stable action ID expected by `MenuBarContent`
- `PluginHost()` includes `disk-clean` in panel/feature management items

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanPluginTests test`

Expected: FAIL because plugin/UI integration does not exist.

- [ ] **Step 3: Implement plugin and UI**

Implement:

- `DiskCleanFeature.shared` with a shared controller instance for plugin/window
- `DiskCleanPlugin` as a disclosure-style plugin ordered before physical clean mode
- panel controls for three choices, scan, open detail, and cancel when active
- `Window("磁盘清理", id: "disk-clean")` in `MacToolsApp`
- `DiskCleanDetailView` using the shared controller
- `MenuBarContent` special-case for the disk-clean open-detail action ID to call `openWindow(id: "disk-clean")`

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild ... DiskCleanPluginTests test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Features/DiskClean Sources/App/MacToolsApp.swift Sources/App/MenuBarContent.swift Sources/Core/Plugins/PluginHost.swift Tests/Features/DiskClean/DiskCleanPluginTests.swift
git commit -m "feat(clean): add disk clean plugin UI"
```

## Task 10: Documentation and Full Verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Document:

- existing "清洁模式" means physical clean mode
- new "磁盘清理" means disk/cache cleanup
- first version scope is cache, developer cache, and browser cache cleanup
- safety protections include whitelist, path validation, and sensitive data protection

- [ ] **Step 2: Run focused tests**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData -only-testing:MacToolsTests/DiskCleanModelsTests -only-testing:MacToolsTests/DiskCleanWhitelistStoreTests -only-testing:MacToolsTests/DiskCleanSafetyPolicyTests -only-testing:MacToolsTests/DiskCleanFileSystemTests -only-testing:MacToolsTests/DiskCleanRuleCatalogTests -only-testing:MacToolsTests/DiskCleanScannerTests -only-testing:MacToolsTests/DiskCleanExecutorTests -only-testing:MacToolsTests/DiskCleanControllerTests -only-testing:MacToolsTests/DiskCleanPluginTests test`

Expected: PASS.

- [ ] **Step 3: Run full tests**

Run: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test`

Expected: PASS.

- [ ] **Step 4: Build app**

Run: `make build`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(clean): document disk cleanup"
```

- [ ] **Step 6: Review final diff**

Run: `git status --short` and `git diff origin/main...HEAD --stat`.

Expected: working tree clean, diff contains only disk-clean feature files, README, and docs/spec/plan files.
