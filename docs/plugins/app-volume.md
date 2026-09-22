# App Volume Plugin

The App Volume plugin provides per-application output volume controls on macOS 15 or later. It discovers Core Audio processes that are currently producing output, groups helper processes under their responsible foreground application, and stores each app's preferred volume locally by bundle identifier.

## Background Discovery

Discovery runs on a serial utility queue. Core Audio listeners watch the process list, each process's output activity, IO running state, output-scoped device list, the default output device, and audio-service restarts. The IO and device notifications matter because some HAL versions do not notify `IsRunningOutput` itself. Events within 50 milliseconds share a refresh; new process listeners are installed before reading activity. A complete reconciliation every ten seconds recovers missed events. Failed subscriptions or incomplete property reads retain the original one-second retry interval until recovery.

An unsuccessful process-list read does not discard the last known routes or subscriptions. A successful empty list does. Removed listeners, stopped sessions, and restarted services invalidate queued callbacks. Listener blocks are removed with the same property, queue, and block used for registration. Audio-service restart rebuilds subscriptions as required by [Core Audio](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyservicerestarted).

Panel visibility does not suspend discovery or audio processing. Explicit refresh remains immediate on the discovery queue; unchanged snapshots do not notify the host. The monitor rejects deliveries queued by an earlier activation, including deliveries already waiting on the main actor when the plugin stops.

## Audio Routing

For every app whose preferred volume is below 100%, the plugin creates a private Core Audio process tap and a private aggregate output route. The tap suppresses the app's original path only while MacTools is actively reading it. The real-time callback applies a short gain ramp and writes the adjusted PCM samples to the current output device. Returning an app to 100%, stopping playback, changing the output device, disabling the plugin, or quitting MacTools removes the route and restores the original path.

The first release supports standard two-channel output devices. It does not create a route when the current output layout cannot be confirmed as stereo, preventing an incompatible buffer layout from muting or corrupting multi-channel output.

## Privacy and Permission

macOS requires System Audio Recording permission before one app can process another app's audio. MacTools requests this permission only after the user moves an app below 100% or explicitly checks the permission card. Audio processing stays in the real-time Core Audio callback and is never recorded, saved, or uploaded.

## Development Validation

Generate the plugin targets and run the focused tests with:

```bash
make generate
xcodebuild \
  -project MacTools.xcodeproj \
  -scheme MacTools \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  test \
  -only-testing:MacToolsTests/AppVolumePluginTests \
  -only-testing:MacToolsTests/AudioApplicationObservationTests \
  -only-testing:MacToolsTests/CoreAudioApplicationMonitorTests
```

Manual audio validation should cover built-in speakers, wired headphones, Bluetooth output, output-device switching while audio is playing, app termination, plugin disable, and permission denial.
