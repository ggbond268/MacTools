import SwiftUI

/// The host owns layout; plugins choose one of its supported renderers.
public enum PluginPanelItemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case row
    case widget
}

/// A suggestion applied once when an item is first discovered, never on refresh.
public enum PluginPanelInitialPlacement: String, Codable, Hashable, Sendable {
    case dashboard
    case featurePanel
}

/// A lightweight snapshot. IDs and renderer kinds stay stable across updates.
/// Titles, states, and widget dimensions may change after `onStateChange`.
@MainActor
public struct PluginPanelItem: Identifiable {
    public let id: String
    public let title: String?
    public let description: String?
    public let systemImage: String?
    public let iconTint: Color?
    public let initialPlacement: PluginPanelInitialPlacement?
    public let content: PluginPanelContent
    public let visibilityHandler: ((Bool) -> Void)?

    public var kind: PluginPanelItemKind {
        switch content {
        case .row: .row
        case .widget: .widget
        }
    }

    public init(
        id: String,
        title: String? = nil,
        description: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        initialPlacement: PluginPanelInitialPlacement? = nil,
        content: PluginPanelContent,
        visibilityHandler: ((Bool) -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.initialPlacement = initialPlacement
        self.content = content
        self.visibilityHandler = visibilityHandler
    }

    public static func row(
        id: String,
        title: String? = nil,
        description: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        initialPlacement: PluginPanelInitialPlacement? = nil,
        descriptor: PluginPanelRowDescriptor,
        state: PluginPanelRowState,
        action: @escaping (PluginPanelAction) -> Void
    ) -> Self {
        Self(id: id, title: title, description: description, systemImage: systemImage,
             iconTint: iconTint, initialPlacement: initialPlacement,
             content: .row(PluginPanelRow(descriptor: descriptor, state: state, action: action)))
    }

    public static func widget<Content: View>(
        id: String,
        title: String? = nil,
        description: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        initialPlacement: PluginPanelInitialPlacement? = nil,
        descriptor: PluginPanelWidgetDescriptor,
        state: PluginPanelWidgetState,
        detail: ((String, @escaping () -> Void) -> PluginPanelDetailContent?)? = nil,
        @ViewBuilder content: @escaping (PluginPanelWidgetContext) -> Content
    ) -> Self {
        Self(id: id, title: title, description: description, systemImage: systemImage,
             iconTint: iconTint, initialPlacement: initialPlacement,
             content: .widget(PluginPanelWidget(
                descriptor: descriptor, state: state, detail: detail,
                content: { AnyView(content($0)) }
             )))
    }

    /// Aggregated across placements in the presented panel. Preview creation and
    /// viewport mounting never start or stop plugin business work.
    public func onVisibilityChange(_ handler: @escaping (Bool) -> Void) -> Self {
        Self(id: id, title: title, description: description, systemImage: systemImage,
             iconTint: iconTint, initialPlacement: initialPlacement,
             content: content, visibilityHandler: handler)
    }
}

@MainActor
public enum PluginPanelContent {
    case row(PluginPanelRow)
    case widget(PluginPanelWidget)
}

@MainActor
public struct PluginPanelRow {
    public let descriptor: PluginPanelRowDescriptor
    public let state: PluginPanelRowState
    public let action: (PluginPanelAction) -> Void

    public init(descriptor: PluginPanelRowDescriptor, state: PluginPanelRowState,
                action: @escaping (PluginPanelAction) -> Void) {
        self.descriptor = descriptor
        self.state = state
        self.action = action
    }
}

@MainActor
public struct PluginPanelWidget {
    public let descriptor: PluginPanelWidgetDescriptor
    public let state: PluginPanelWidgetState
    public let makeDetail: ((String, @escaping () -> Void) -> PluginPanelDetailContent?)?
    public let makeView: (PluginPanelWidgetContext) -> AnyView

    public init(descriptor: PluginPanelWidgetDescriptor, state: PluginPanelWidgetState,
                detail: ((String, @escaping () -> Void) -> PluginPanelDetailContent?)? = nil,
                content: @escaping (PluginPanelWidgetContext) -> AnyView) {
        self.descriptor = descriptor
        self.state = state
        self.makeDetail = detail
        self.makeView = content
    }
}
