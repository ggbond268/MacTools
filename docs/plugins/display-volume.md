# Display Volume

Display Volume adjusts external-display audio through DDC/CI VCP `0x62` on Apple Silicon. Its panel provides per-display sliders; shortcuts can follow the mouse or target all available displays. It requires a compatible display and connection with DDC/CI enabled.

## Panel integration

The plugin requires PluginKit 7 and host 1.3.1 or later. It declares a stable `control` row through `panelItems`, initially placed in the feature panel. The row starts collapsed; the host owns expansion for each placement and requests slider details through the row action. Snapshot reads never reset that demand. The plugin remains row-only because per-display sliders need the full detail layout; shortcuts, canonical actions, and settings keep their existing identifiers.

## Reading and writing

- `DDCVolumeBackend.cachedVolume` returns an existing snapshot without hardware I/O. A saved zero is preserved; missing or invalid saved values start at 15%.
- The controller owns background reads, coalesces outstanding refreshes per display, and publishes completed values on `MainActor` before notifying the host. Snapshot getters perform no DDC calls.
- The transport validates the complete 11-byte Get VCP response: source `0x6E`, length `0x88`, reply opcode `0x02`, success status `0x00`, feature `0x62`, and checksum.
- When GET is unavailable, the backend retains its last saved volume estimate. It persists SET values only after the transport succeeds. Transport success does not guarantee a display applied the command; a supported GET provides readback confirmation.
- New writes, disconnects, and deactivation invalidate older reads. Backend I/O is serialized separately from the snapshot lock, so hardware access cannot block snapshot getters or let an older read overwrite a newer write.

## Verification

Run `make generate`, then append these selectors to the repository's focused `xcodebuild test` command:

```sh
-only-testing:MacToolsTests/Arm64DDCTransportTests \
-only-testing:MacToolsTests/DisplayVolumeControllerTests \
-only-testing:MacToolsTests/DisplayVolumePluginTests
```

The tests use synthetic display IDs and fake DDC transports. They cover valid and malformed replies, cached mute, failed writes, background snapshot publication, relative actions, refresh coalescing, and stale reads during writes, disconnects, or deactivation.

For hardware acceptance, use a compatible external display at a low volume. Verify a standard GET reply, change volume through the plugin, and confirm the display's own control reflects it. After reconnecting, verify synchronization before using a relative shortcut. On a display without volume GET support, verify the saved estimate survives restart, including zero. Record the display model, connection, and GET support with results; simulated tests do not establish device compatibility.
