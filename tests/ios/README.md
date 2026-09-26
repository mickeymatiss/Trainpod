# Focused theme-controller characterization

This separate simulator harness compiles the actual `DeviceUIColor` and `DeviceTheme` sources. Two small transport-facing doubles expose readiness, callbacks and captured control packets; they do not implement CoreBluetooth, persistence or radio behavior.

Supply an already booted iOS 26.5+ simulator and an output directory outside the checkout:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 tests/run_theme_controller_test.py --device SIMULATOR_UDID --output /tmp/keytrain-theme-check
```

The runner builds a tiny UIKit test app, signs it ad hoc for the simulator, installs/runs it, and uninstalls it afterward. It never boots, shuts down or erases the supplied simulator and does not modify the app project. Do not run concurrent copies on the same simulator: they use the same temporary bundle ID. It checks an explicit PASS marker because `simctl launch` can return zero after an app assertion failure.

Cases cover A confirming X, switching to B without carrying confirmation, live edit to X on B, switching back to A, same-connection deduplication, explicit manual Push and six fields plus the commit packet. A/B are connection-boundary events supplied to the real controller, not physical devices. Awaiting sends uses actor yields with a bounded iteration/process deadline; the check does not use network or BLE hardware. The harness failed against the original controller at the stale-confirmation assertion and passed after F05.

This is separate from the macOS Swift/C++ host runner; UIKit is required. Physical theme delivery/persistence and actual two-device BLE switching remain manual checks.
