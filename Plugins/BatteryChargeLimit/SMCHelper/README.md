This directory holds the source for the bundled Battery SMC helper.

The helper binary is built as `mactools-battery-smc-helper` and copied into
`BatteryChargeLimit.bundle/Contents/Resources/SMCHelper/` by the generated
Xcode project. The plugin installs it to `/Library/PrivilegedHelperTools` with
root ownership and setuid permissions on first use.

The helper exposes these subcommands:

  probe              Output which charge-control SMC keys are writable
  inhibit [<pct>]    Stop charging (prefers BCLM soft ceiling; falls back to CHTE or CH0B+CH0C)
  resume             Clear inhibit keys and stop force-discharge
  discharge on|off   Toggle the available adapter-isolation key (CHIE, CH0J, or CH0I)
  read <KEY>         Print the current value of a 1-byte SMC key
