import Combine

/// The retained panel tree observes completed panel updates only while visible.
/// Plugin-owned monitoring and snapshots keep their independent lifecycles.
@MainActor
final class MenuBarPanelPresentationModel: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var isVisible: Bool
    private var subscription: AnyCancellable?

    init(host: PluginHost, isVisible: Bool = false) {
        self.isVisible = isVisible
        subscription = host.menuBarPanelContentDidChange.sink { [weak self] in
            guard let self, self.isVisible else { return }
            self.revision &+= 1
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            // Catch up from the host's latest state, without queuing hidden updates.
            revision &+= 1
        }
    }
}
