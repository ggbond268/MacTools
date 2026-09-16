import AppKit
import Foundation

/// Placement is chosen from plugin settings, but arbitrated and persisted by the host.
public enum PluginMenuBarIconPlacement: String, Equatable, Sendable {
    case standalone
    case primary
}

public struct PluginMenuBarIconDescriptor: Identifiable, Equatable, Sendable {
    /// Stable within the providing plugin; never use a localized title as the identifier.
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct PluginMenuBarIconOwner: Equatable, Sendable {
    public let pluginID: String
    public let iconID: String
    public let pluginTitle: String
    /// The owner is reserved for an updated plugin that cannot reload until host restart.
    public let requiresRestart: Bool

    public init(pluginID: String, iconID: String, pluginTitle: String, requiresRestart: Bool = false) {
        self.pluginID = pluginID
        self.iconID = iconID
        self.pluginTitle = pluginTitle
        self.requiresRestart = requiresRestart
    }
}

public enum PluginMenuBarIconPlacementError: Error, Equatable, Sendable {
    case occupied(owner: PluginMenuBarIconOwner)
    case unavailable
    case invalidIcon
}

public struct PluginMenuBarIconRenderContext: Equatable, Sendable {
    public enum Appearance: Equatable, Sendable {
        case light
        case dark
    }

    public let pointSize: CGSize
    public let displayScale: CGFloat
    public let appearance: Appearance

    public init(pointSize: CGSize, displayScale: CGFloat, appearance: Appearance) {
        self.pointSize = pointSize
        self.displayScale = displayScale
        self.appearance = appearance
    }
}

/// A snapshot, not a live view. The provider must not mutate an image after publishing it.
@MainActor
public struct PluginMenuBarIconSnapshot {
    /// Change whenever the image, tooltip, or accessibility description changes.
    public let revision: UInt64
    public let image: NSImage
    public let isTemplate: Bool
    public let tooltip: String
    public let accessibilityDescription: String

    public init(
        revision: UInt64,
        image: NSImage,
        isTemplate: Bool,
        tooltip: String,
        accessibilityDescription: String
    ) {
        self.revision = revision
        self.image = image
        self.isTemplate = isTemplate
        self.tooltip = tooltip
        self.accessibilityDescription = accessibilityDescription
    }
}

/// Optional capability: does not add requirements to the MacToolsPlugin witness table.
@MainActor
public protocol PluginMenuBarIconProviding: AnyObject {
    var menuBarIconDescriptors: [PluginMenuBarIconDescriptor] { get }
    /// Signal only changed icons. Do not use onStateChange for high-frequency icon updates.
    var onMenuBarIconChange: ((String) -> Void)? { get set }
    /// Read cached business state only; never perform hardware, filesystem, or network I/O here.
    func menuBarIcon(
        for iconID: String,
        context: PluginMenuBarIconRenderContext
    ) -> PluginMenuBarIconSnapshot?
}

/// A revocable, plugin-scoped capability. Callers cannot impersonate another plugin.
@MainActor
public struct PluginMenuBarIconHostContext {
    private let placementHandler: (String) -> PluginMenuBarIconPlacement
    private let ownerHandler: () -> PluginMenuBarIconOwner?
    private let requestHandler: (PluginMenuBarIconPlacement, String) -> Result<Void, PluginMenuBarIconPlacementError>

    public init(
        placement: @escaping (String) -> PluginMenuBarIconPlacement,
        primaryIconOwner: @escaping () -> PluginMenuBarIconOwner?,
        requestPlacement: @escaping (
            PluginMenuBarIconPlacement, String
        ) -> Result<Void, PluginMenuBarIconPlacementError>
    ) {
        placementHandler = placement
        ownerHandler = primaryIconOwner
        requestHandler = requestPlacement
    }

    public var primaryIconOwner: PluginMenuBarIconOwner? { ownerHandler() }

    public func placement(for iconID: String) -> PluginMenuBarIconPlacement {
        placementHandler(iconID)
    }

    /// Failure leaves both the current placement and the stored preference unchanged.
    public func requestPlacement(
        _ placement: PluginMenuBarIconPlacement,
        for iconID: String
    ) -> Result<Void, PluginMenuBarIconPlacementError> {
        requestHandler(placement, iconID)
    }
}

@MainActor
public protocol PluginMenuBarIconHostContextConsuming: AnyObject {
    /// Nil before registration and after revocation. Do not create a replacement entry then.
    var menuBarIconHostContext: PluginMenuBarIconHostContext? { get set }
    /// Low-frequency ownership changes only. Query the context for the current state.
    func menuBarIconPlacementDidChange()
}
