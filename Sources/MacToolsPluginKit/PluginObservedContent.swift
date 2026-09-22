import Combine
import SwiftUI

private struct PluginPresentationVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// Hosts set this to false for retained content that is not currently displayed.
    /// Standalone windows and settings previews observe their models by default.
    var pluginPresentationIsVisible: Bool {
        get { self[PluginPresentationVisibilityKey.self] }
        set { self[PluginPresentationVisibilityKey.self] = newValue }
    }
}

/// Observes a main-actor model only while this presentation is visible. The model
/// keeps collecting data independently; reopening reads its latest state. Content
/// should read the supplied model without adding another ObservedObject subscription.
@MainActor
public struct PluginObservedContent<Source: ObservableObject, Content: View>: View {
    private let source: Source
    private let content: (Source) -> Content
    @Environment(\.pluginPresentationIsVisible) private var isVisible
    @StateObject private var observation = PluginPresentationObservation()

    public init(_ source: Source, @ViewBuilder content: @escaping (Source) -> Content) {
        self.source = source
        self.content = content
    }

    public var body: some View {
        content(source)
            .onAppear { observation.observe(source, isVisible: isVisible) }
            .onChange(of: isVisible) { _, visible in observation.observe(source, isVisible: visible) }
            .onChange(of: ObjectIdentifier(source)) { _, _ in observation.observe(source, isVisible: isVisible) }
            .onDisappear { observation.disconnect() }
    }
}

@MainActor
final class PluginPresentationObservation: ObservableObject {
    private var sourceID: ObjectIdentifier?
    private var subscription: AnyCancellable?

    func observe<Source: ObservableObject>(_ source: Source, isVisible: Bool) {
        guard isVisible else {
            disconnect()
            return
        }
        guard sourceID != ObjectIdentifier(source) else { return }
        disconnect()
        sourceID = ObjectIdentifier(source)
        subscription = source.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Catch changes that happened while detached, including between rendering
        // the view and installing its subscription in onAppear.
        objectWillChange.send()
    }

    func disconnect() {
        subscription = nil
        sourceID = nil
    }
}
