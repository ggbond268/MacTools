# Window Switcher development

The redesign uses per-process Accessibility workers and a native, nonactivating searchable chooser. Activation targets use live AX identity; capture metadata never determines the action destination. Screen Recording permission is optional for core switching.

See the [interaction contract and acceptance record](../superpowers/specs/2026-09-10-window-switcher-redesign.md) and [isolated Chrome diagnostic](../../scripts/diagnostics/window-switcher/README.md). The diagnostic runs against a temporary profile, fails on unexpected native outcomes, and does not install a packaged plugin.

The plugin manifest targets PluginKit v6 and publishes both All Windows and Current App Windows actions. The host shortcut-resolution change and plugin listener should be reviewed and released together. Existing custom or cleared shortcuts remain authoritative, and selecting the companion preset changes inherited defaults. Do not claim release readiness from model tests alone; record physical IME, fullscreen, Spaces, displays, and save-dialog acceptance separately.
