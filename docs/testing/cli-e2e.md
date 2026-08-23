# CLI end-to-end verification

The mutual-authentication path requires a normally signed Debug or Release app;
an unsigned XCTest host cannot register an `SMAppService` LaunchAgent.

1. Configure `LocalConfig.xcconfig`, then run `make build-plugin` and `make run`.
2. In Settings > General > Command Line, install the command and approve the
   background item if macOS requests it.
3. Quit MacTools, then run `~/.local/bin/mactools doctor --json`. Verify that the
   app cold-starts, the protocol is `1`, and no Settings window is activated.
4. Run `actions list --runnable`, describe one safe parameterless action, and
   execute it. Verify that the same result/history appears in MacTools.
5. Run a cancellable action and press Control-C. Verify exit `8` when the host
   confirms cancellation.
6. Pass a distinctive secret through `--input-json -`, force a provider error,
   and verify the value does not appear in JSON, Console, or diagnostics.
7. Inspect nested signatures and the LaunchAgent:

```bash
APP="$HOME/Applications/MacTools Dev.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP/Contents/MacOS/mactools"
codesign -dv --verbose=4 "$APP/Contents/MacOS/MacToolsCLIBroker"
plutil -p "$APP/Contents/Library/LaunchAgents/app.ggbond.MacTools.cli-broker.plist"
```

The signing identifiers must end in `.mactools.dev`, `.mactools.dev.cli`, and
`.mactools.dev.cli-broker`, with matching non-empty Team identifiers.
