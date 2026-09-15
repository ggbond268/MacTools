# App Uninstaller

App Uninstaller implements the reviewed, user-domain Trash milestone of [issue #350](https://github.com/ggbond268/MacTools/issues/350), following the maintainer's scope clarification. Users choose, browse for, or drop one application, inspect ownership evidence and data consequences, select eligible items, review an immutable list, quit the app, and explicitly confirm moving the selection to Trash.

The only canonical action is `app-uninstaller/open-review`. It opens the foreground workspace. It accepts no parameters and exposes no removal, automatic, workflow, or external-invocation action. Homebrew navigation opens the existing Homebrew settings; it does not invoke package management.

## Reviewed scope

Applications can be inspected from a selected path. Removal accepts an ordinary app below `/Applications` or `~/Applications`, including organization subfolders, after identity and safety checks. Embedded applications, system apps, Apple identifiers, MacTools, and apps outside these roots are protected. The inventory includes hidden entries, reviewed application roots, discoverable embedded apps, and running applications. Unreadable or bounded-out inventory prevents removal.

Associated paths use exact bundle identifiers in these fixed user Library locations:

| Location | Evidence | Selection and removal |
| --- | --- | --- |
| `Caches/<bundle ID>` | Exact identifier | Selected if eligible |
| `Logs/<bundle ID>` | Exact identifier | Selected if eligible |
| `Preferences/<bundle ID>.plist` | Exact preference domain; regular file | Selected if eligible |
| `Saved Application State/<bundle ID>.savedState` | Exact saved-state identifier | Selected if eligible |
| `Application Support/<bundle ID>` | Exact identifier | Unselected; explicit review required |
| `Containers/<bundle ID>` | Matching container metadata | Unselected; explicit review required |
| `Group Containers/<group ID>` | Verified signing entitlement | Shared and protected from removal |

Ownership confidence and data sensitivity are separate. Databases, chat history, downloaded models, preferences, and saved state can be valuable even with strong ownership evidence. A second installed app with the same identifier, including a case variant on a case-insensitive filesystem, protects associated data. A Team ID or similar name never authorizes removal. Missing or conflicting container metadata cannot authorize removal.

The scanner does not search Documents, projects, arbitrary vendor folders, ByHost preferences, HTTPStorages, WebKit, Cookies, Application Scripts, or the entire disk. Local-domain shared data and privileged services are outside removal scope. Coverage lists actual checks and limitations; an absent match never means that all app data was found. Estimates use allocated blocks and deduplicate hard links within each candidate. They are not a measurement of reclaimed space, and moving to Trash does not release space.

## Installation and process boundaries

- Standard Homebrew Caskrooms are inspected for application claims. Claimed apps must use Homebrew. Nonstandard package managers and custom installations cannot be proven absent; unknown-source confirmation requires checking the original installation method and developer instructions.
- An App Store receipt is an observed file, not verified purchase or management evidence.
- Managed or indeterminate device enrollment prevents removal. This intentionally protects every app on a managed device rather than attempting to override administrator policy for individual apps.
- Privileged helpers, embedded service declarations, system or driver extensions, attributable launch services, and possible vendor uninstallers lead to vendor/manual guidance. Launch metadata is read as data and never executed. Vendor tools are revealed in Finder for user inspection. Detection is bounded and does not claim to discover every external service, extension, custom manager, or vendor tool.
- Main applications and executable paths inside the selected bundle must be stopped. Quit targets only the selected running app; Force Quit is a separate explicit confirmation. Unrelated or privileged processes are never terminated.
- A live process belonging to the current user whose executable path cannot be inspected makes process coverage incomplete and blocks removal. Recheck is available after the condition changes. Unreadable processes belonging only to other users are outside this user-domain process check; installation checks and vendor guidance remain necessary for privileged services.
- Full Disk Access is probed without reading protected database contents. An unavailable probe is not reported as granted. The settings action opens the native privacy pane, while scan coverage reports actual readability.

## Execution and recovery

Plans expire five minutes after the scan. Selection changes and rescanning invalidate pending confirmation. Before every item, execution refreshes installation restrictions, the application inventory, ownership evidence, identity, contents metadata, process state, and plan freshness. Associated items precede the application bundle so later checks still have the original application identity.

Filesystem access rejects symlink ancestors, nonlocal volumes, and special files. Tree traversal is bounded by depth, entry count, time, and cancellation; it does not follow symlinks or cross mounts. Item type, device/inode, size, timestamps, and a deterministic tree metadata digest must match the reviewed snapshot. These checks detect ordinary concurrent changes; they are not a guarantee against an adversarial process racing the final operating-system operation.

Before moving an item, a durable history record names a private staging location beside the original. An anchored, exclusive rename stages the item, then identity, tree, process, and expiry checks run again. Only the native Trash API performs removal. There is no permanent-delete fallback, privilege escalation, or Trash emptying. Failed checks restore the original without overwriting a replacement. If restoration cannot be verified, the record retains the staging path and visibly requires attention. Execution stops after a failure or cancellation and preserves completed and retained outcomes.

History stores original paths, known Trash destinations, per-item results, and estimated size under the plugin's scoped support directory. Up to 50 ordinary finished records are retained. Interrupted and attention records survive retention and Clear Finished Records. Copy Diagnostics is explicit and redacts the home-directory prefix; other file names and paths can remain sensitive. Restoring an app from Trash is not a promise to recover all state.

## Implementation provenance

This is an independent implementation using Foundation, AppKit, Security, CryptoKit, and Darwin APIs. No third-party uninstaller code, path database, or heuristic list is incorporated. Product references informed interaction boundaries only.

The issue's draft storage work was not merged into this plugin. The narrow filesystem identity, bounded traversal, immutable plan, and Trash adapter remain private and have focused adversarial fixture coverage. Sharing those primitives with another plugin requires agreeing on the same safety contract and separate integration review; this change does not widen Disk Cleanup or PluginKit authority.

Primary references used to establish the boundaries:

- [Apple: Delete or uninstall apps on Mac](https://support.apple.com/en-us/102610) supports preferring a vendor uninstaller and the Trash workflow.
- [Apple: Code-signing information dictionary keys](https://developer.apple.com/documentation/security/signing-information-dictionary-keys) describes identity and entitlement metadata.
- [Apple: Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) establishes shared-container semantics.
- [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) describes package-owned uninstall and service behavior; MacTools does not copy cask removal rules.

## Validation and manual acceptance

Implementation validation on September 12, 2026 passed the unsigned plugin build, all 38 targeted host tests (37 adjacent plugin tests plus runtime/manifest consistency), and all 254 repository script tests. Two independent reviewers iterated on the implementation and reported no remaining P1/P2 findings. Native fixture workspace renders were checked at 880 points in light appearance and 650 points in dark appearance. A fixture confirmation sheet presented and dismissed, but its bitmap capture was blank, so confirmation-sheet visual acceptance is not claimed.

Regenerate targets with `make generate`. Run the adjacent safety, execution, controller, and plugin tests using the MacTools scheme and `-only-testing:MacToolsTests/AppUninstallerSafetyTests`, `-only-testing:MacToolsTests/AppUninstallerExecutionTests`, `-only-testing:MacToolsTests/AppUninstallerControllerTests`, and `-only-testing:MacToolsTests/AppUninstallerPluginTests`. Use the configured Xcode developer directory and an isolated derived-data path. Run `make script-tests` for manifest and PluginKit compatibility checks, and build the `AppUninstallerPlugin` scheme without signing for compilation validation.

Removal tests use temporary application/Library fixtures and an injected fake Trash directory. They never uninstall real applications, remove user data, or invoke the real Trash service. They exercise changed identities and trees, hidden and conflicting owners, invalid paths and symlinks, running helpers, expiration, cancellation, failed Trash recovery, durable-journal failures, and protected history.

Release acceptance still requires the installed host's picker/drop and permission flows, ordinary and force quit with disposable apps, real Trash destinations and restoration, protected/read-only locations, interrupted-operation recovery, and accessibility/keyboard checks at supported window sizes. Automated and rendered fixture checks do not establish those live operating-system behaviors. These checks do not sign, install, or publish a release.
