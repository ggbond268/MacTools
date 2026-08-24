import AppKit
import Foundation
import SwiftUI

@MainActor
public protocol MacToolsPlugin: AnyObject {
    var metadata: PluginMetadata { get }
    var primaryPanel: (any PluginPrimaryPanel)? { get }
    var componentPanel: (any PluginComponentPanel)? { get }
    var permissionRequirements: [PluginPermissionRequirement] { get }
    var shortcutDefinitions: [PluginShortcutDefinition] { get }
    var settingsPage: PluginSettingsPage? { get }
    var onStateChange: (() -> Void)? { get set }
    var requestPermissionGuidance: ((String) -> Void)? { get set }
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)? { get set }

    func refresh()
    func activate(context: PluginRuntimeContext)
    func deactivate(reason: PluginDeactivationReason)
    func permissionState(for permissionID: String) -> PluginPermissionState
    func handlePermissionAction(id: String)
    func handleSettingsAction(_ action: PluginSettingsAction)
    func handleShortcutAction(id: String)
}

@MainActor
public protocol PluginPrimaryPanel: AnyObject {
    var primaryPanelDescriptor: PluginPrimaryPanelDescriptor { get }
    var primaryPanelState: PluginPanelState { get }

    func handleAction(_ action: PluginPanelAction)
}

/// Optional capability for a plugin settings page with its own contextual search field.
/// The Settings host invokes this when the user presses Command-F on that page.
@MainActor
public protocol PluginSettingsSearchFocusing: AnyObject {
    func focusSettingsSearch()
}

public enum PluginShortcutEventPhase: Sendable {
    case pressed
    case released
}

@MainActor
public protocol PluginShortcutEventHandling: AnyObject {
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase)
}

public extension MacToolsPlugin {
    var primaryPanel: (any PluginPrimaryPanel)? {
        nil
    }

    var componentPanel: (any PluginComponentPanel)? {
        nil
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        []
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        []
    }

    var settingsPage: PluginSettingsPage? {
        nil
    }

    func refresh() {}

    func activate(context: PluginRuntimeContext) {}

    func deactivate(reason: PluginDeactivationReason) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

public extension MacToolsPlugin where Self: PluginPrimaryPanel {
    var primaryPanel: (any PluginPrimaryPanel)? {
        self
    }
}

@MainActor
public protocol PluginComponentPanel: AnyObject {
    var descriptor: PluginComponentDescriptor { get }
    var componentPanelState: PluginComponentState { get }

    func makeView(context: PluginComponentContext) -> AnyView
}

public extension MacToolsPlugin where Self: PluginComponentPanel {
    var componentPanel: (any PluginComponentPanel)? {
        self
    }
}

public enum PluginPanelSurface: CaseIterable, Hashable, Sendable {
    case component
    case primary
}

@MainActor
public protocol PluginPanelSurfaceLifecycleHandling: AnyObject {
    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface)
    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface)
}

public extension PluginPanelSurfaceLifecycleHandling {
    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {}
    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {}
}

@MainActor
public protocol PluginProvider {
    func makePlugins() -> [any MacToolsPlugin]
}

public protocol MacToolsPluginBundleFactory: AnyObject {
    static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider
}

@MainActor
public protocol AccessibilityPermissionRefreshing {
    func refreshAccessibilityPermission()
}

@MainActor
public protocol DisplayTopologyRefreshing {
    func refreshDisplayTopology()
}

/// Optional preflight contract for a plugin that takes ownership of behavior extracted from
/// another package. This is a separate protocol so existing plugin witness tables remain stable.
@MainActor
public protocol PluginFeatureExtractionReadinessProviding: AnyObject {
    func validateFeatureExtractionReadiness() throws
}

/// Optional protocol for plugins that expose a compact, read-only status in the primary panel row.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol PluginPrimaryPanelIndicatorProviding: AnyObject {
    var primaryPanelIndicator: PluginPrimaryPanelIndicator? { get }
}

/// Optional protocol for plugins that expose one or more icon-only statuses in the primary panel row.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol PluginPrimaryPanelCompactIndicatorProviding: AnyObject {
    var primaryPanelCompactIndicator: PluginPrimaryPanelCompactIndicator? { get }
}

/// Optional protocol for plugins that need a floating-window anchor.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol DropZoneAnchorProviding: AnyObject {
    /// Host-injected provider returning the status-item button frame in screen coordinates.
    var anchorRectProvider: (() -> NSRect?)? { get set }
}

/// Optional protocol for plugins that need to protect the host menu-bar status-item position.
@MainActor
public protocol MenuBarHostStatusItemRecovering: AnyObject {
    var hostStatusItemFrameProvider: (() -> NSRect?)? { get set }
    var resetHostStatusItemPosition: (() -> Void)? { get set }
}

/// Optional protocol for plugins that need to open their settings page from custom UI, such as a floating panel.
@MainActor
public protocol PluginSettingsPresenting: AnyObject {
    var requestSettingsPresentation: (() -> Void)? { get set }
}

/// An exact host-selected window target for commands that may outlive a temporary MacTools surface.
/// `preferredWindowNumber` is required when the target belongs to MacTools so plugins can exclude
/// transient search, grid, confirmation, and feedback panels.
public struct PluginFocusedWindowTarget {
    public let application: NSRunningApplication
    public let preferredWindowNumber: Int?

    public init(
        application: NSRunningApplication,
        preferredWindowNumber: Int? = nil
    ) {
        self.application = application
        self.preferredWindowNumber = preferredWindowNumber
    }
}

/// Optional host context for commands that must continue targeting the exact window focused before
/// a MacTools search, grid, or other transient action surface became active.
@MainActor
public protocol PluginFocusedWindowTargetConsuming: AnyObject {
    var focusedWindowTargetProvider: (() -> PluginFocusedWindowTarget?)? { get set }
}

/// Optional hook for built-in plugins that cache localized descriptors or
/// other language-dependent presentation data. The host invokes it when the
/// app language changes; implementations must not activate, deactivate, or
/// reset the plugin's functional state. Dynamic plugins read localization at
/// render time and do not need this hook.
@MainActor
public protocol PluginRuntimeLocalizationRefreshing: AnyObject {
    func refreshLocalization()
}

/// Optional hook for plugins whose dynamic shortcut definitions need to retain a shortcut after
/// the host accepts, clears, or restores its binding. Registration and conflict validation remain
/// owned by the host's shared shortcut manager.
@MainActor
public protocol PluginShortcutBindingChangeHandling: AnyObject {
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?)
}

/// Optional protocol for plugins that explicitly opt a small, non-sensitive settings payload
/// into MacTools preferences backup and restore. This preserves the `MacToolsPlugin` ABI for
/// existing dynamic plugins while keeping cache, credentials, and other private data excluded.
@MainActor
public protocol PluginPortablePreferencesProviding: AnyObject {
    func makePortablePreferencesBackup() -> Data?
    func restorePortablePreferences(from data: Data)
}

/// Optional signal for plugins that persist portable preferences outside the
/// host's UserDefaults-backed stores. Emit only after a meaningful preference
/// mutation, never for live status refreshes or cache updates.
@MainActor
public protocol PluginPersistentPreferencesChangeSignaling: AnyObject {
    var onPersistentPreferencesChange: (() -> Void)? { get set }
}

/// Delivers successful portable-preference persistence to the host, buffering
/// a construction-time migration until the host installs its callback.
@MainActor
public final class PluginPersistentPreferencesChangeEmitter {
    public var onChange: (() -> Void)? {
        didSet {
            guard onChange != nil, hasPendingChange else { return }
            hasPendingChange = false
            onChange?()
        }
    }

    private var hasPendingChange = false

    public init() {}

    public func didPersist() {
        guard let onChange else {
            hasPendingChange = true
            return
        }
        onChange()
    }
}

/// Optional companion for portable-preference providers that can verify validation and
/// persistence. The host uses this result before restoring actions that depend on the payload.
/// Keeping this separate preserves compatibility with existing dynamic plugins.
@MainActor
public protocol PluginPortablePreferencesRestorationReporting: AnyObject {
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool
}

/// Optional dependency index for portable plugin preferences that embed or define canonical
/// actions. The host persists these references beside the opaque payload so a fresh Mac can
/// offer missing action providers before the surface plugin restores its own settings. Providers
/// whose actions require plugin preferences must enumerate every exact action reference defined
/// by the payload; restore validation fails closed for references that are not enumerated.
@MainActor
public protocol PluginPortablePreferencesActionReferencesProviding: AnyObject {
    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]?
}

/// Describes whether a dynamic action can be restored independently or depends on the
/// plugin's portable preferences payload. Providers only need this hook when the action's
/// portability cannot be expressed by its parameter schema alone.
public enum PluginActionReferenceBackupDisposition: Equatable, Sendable {
    case selfContained
    case requiresPluginPreferences
    case excluded
}

@MainActor
public protocol PluginActionReferenceBackupProviding: AnyObject {
    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition
}

/// A stable identity for a system-wide input gesture currently owned by a plugin.
/// The host uses claims to prevent two independently packaged input plugins from
/// responding to the same physical gesture.
public struct PluginInputGestureClaim: Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Describes another plugin that currently owns a claimed input gesture.
public struct PluginInputGestureConflict: Hashable, Sendable {
    public let claim: PluginInputGestureClaim
    public let ownerPluginID: String
    public let ownerPluginTitle: String

    public init(
        claim: PluginInputGestureClaim,
        ownerPluginID: String,
        ownerPluginTitle: String
    ) {
        self.claim = claim
        self.ownerPluginID = ownerPluginID
        self.ownerPluginTitle = ownerPluginTitle
    }
}

/// Optional companion contract for plugins that listen to system-wide gestures.
@MainActor
public protocol PluginInputGestureClaimProviding: AnyObject {
    var activeInputGestureClaims: [PluginInputGestureClaim] { get }
}

/// Optional host callback for a plugin that must pause or reject a configuration
/// when another plugin owns the same physical gesture.
@MainActor
public protocol PluginInputGestureConflictConsuming: AnyObject {
    func inputGestureConflictsDidChange(_ conflicts: [PluginInputGestureConflict])
}

/// Optional bridge for the sole owner of the private multitouch listener.
@MainActor
public protocol TrackpadGestureEventProviding: AnyObject {
    var requestedTrackpadGestures: Set<TrackpadGesture> { get }
    var onTrackpadGestureRequestsChange: (() -> Void)? { get set }
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)? { get set }
    func setTrackpadGestureOwnership(
        localGestures: Set<TrackpadGesture>,
        externalGestures: Set<TrackpadGesture>,
        handler: @escaping (TrackpadGesture, UInt64) -> Void
    )
}

/// Optional bridge for a plugin that maps the shared precise trackpad gestures.
@MainActor
public protocol TrackpadGestureEventConsuming: AnyObject {
    var claimedTrackpadGestures: Set<TrackpadGesture> { get }
    var onTrackpadGestureClaimsChange: (() -> Void)? { get set }
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)? { get set }
    func setOwnedTrackpadGestures(_ gestures: Set<TrackpadGesture>)
    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64)
}
