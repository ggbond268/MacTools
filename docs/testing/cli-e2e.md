# CLI end-to-end verification

The mutual-authentication path requires a normally signed Debug or Release app;
an unsigned XCTest host cannot register an `SMAppService` LaunchAgent.

1. Configure `LocalConfig.xcconfig`, then run `make build-plugin` and `make run`.
2. Build the standalone client with `make build-cli`, copy
   `build/DerivedData/Build/Products/Debug/MacToolsCLI` to a stable path named
   `mactools`, then enable Settings > General > Command Line. Approve the
   background item if macOS requests it.
3. Quit MacTools, then run the absolute path to `mactools doctor --json`. Verify that the
   app cold-starts, the protocol is `1`, no Settings window is activated, and
   the first action count matches an immediate `actions list` response without
   waiting or retrying.
4. Run `actions list --runnable`, describe one safe parameterless action, and
   execute it. Verify that the same result/history appears in MacTools.
5. Send Control-C immediately after starting a request, while a confirmation is
   visible, and while a cancellable provider is running. Each request must emit
   one cancellation result with exit `8`; dismissing a later confirmation must
   not start the action. Run another CLI command afterward to verify the prior
   signal handlers were restored without leaving the CLI transport stuck.
6. Pass a distinctive secret through `--input-json -`, force a provider error,
   and verify the value does not appear in JSON, Console, or diagnostics.
7. Inspect nested signatures and the LaunchAgent:

```bash
APP="$HOME/Applications/MacTools Dev.app"
CLI="/absolute/path/to/mactools"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$CLI"
codesign -dv --verbose=4 "$APP/Contents/MacOS/MacToolsCLIBroker"
plutil -p "$APP/Contents/Library/LaunchAgents/app.ggbond.MacTools.cli-broker.plist"
```

The host, standalone CLI, and broker signing identifiers must end in `.mactools.dev`, `.mactools.dev.cli`, and
`.mactools.dev.cli-broker`, with matching non-empty Team identifiers.

8. Configure a Saved Script that invokes the same `mactools` path. Start that
   script from the CLI and verify the nested command is rejected with category
   `recursiveInvocation` while the parent request completes normally.
