# Presentation and background work

Collection, user-visible state, and host metadata have separate lifetimes. Hiding a panel must not disable an enabled monitoring service, change sampling guarantees, or discard its interaction state.

## Retained component views

Host 1.3.1 introduces `PluginObservedContent` and `EnvironmentValues.pluginPresentationIsVisible`. The component host sets visibility for the selected panel and its dashboard. Hidden tabs, a closed panel, and dashboards covered by inline details disconnect presentation subscriptions. Standalone windows and settings previews default to visible; ordinary view disappearance also disconnects the subscription.

Use the wrapper around content that reads an `ObservableObject` updated on the main actor:

```swift
let model: MonitorModel

var body: some View {
    PluginObservedContent(model) { model in
        ChartContent(snapshot: model.snapshot)
    }
}
```

Do not also mark the same model as `@ObservedObject` in that retained view or a child; that subscription would bypass the visibility boundary. Other consumers, such as menu-bar indicators, settings, and notification services, keep their independent observations. Each view has its own subscription, so hiding one copy cannot freeze another visible copy. Reopening reads current data once, without replaying hidden updates or changing view identity.

This follows SwiftUI's [observable-object dependency model](https://developer.apple.com/documentation/swiftui/observedobject) and Apple's guidance to [reduce unnecessary view updates](https://developer.apple.com/videos/play/wwdc2023/10160/).

## Frequent input statistics

Keep every event in the business snapshot and preserve persistence scheduling. Publish throttled statistics to component observers. Notify the host about changing count labels only while a corresponding panel surface is visible, then refresh when either the primary or component surface opens. Configuration, permission, and error changes must still notify the host immediately through the normal callback.

## Dynamic shortcut removal

`PluginShortcutResetRequesting` (host 1.3.1+) accepts an optional host callback with plugin-local definition IDs. Invoke it before removing dynamic definitions so the host can resolve them. The host validates each reset, preserves binding-change notifications, and finishes registration changes before returning, rebuilding shared presentation once per batch. Unknown IDs are ignored and cannot target another plugin. A plugin outside the host may leave the callback unset.

The capability is additive; it does not alter the stored layout of `PluginSettingsContext` or other existing PluginKit values. Update minimum-host inventory checks for new API consumers and run the frozen PluginKit v6 client when changing the shared framework.
