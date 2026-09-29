# Optional Mac LCD calibration

This development feature supports the native TrainPod Colorscape Mac app. The Mac displays the fixed target and all 13 candidate swatches; selecting a candidate sends one raw full-screen LCD color over USB serial. The Mac owns and saves all calibration/search data.

## Disable or omit it

In the sketch-root `FirmwareConfig.h`, change:

```cpp
#define KEYTRAIN_COLOR_CALIBRATION 0
```

Rebuild and upload normally. No other source edits are required. You can also leave the source default alone and compile with `-DKEYTRAIN_COLOR_CALIBRATION=0` (Arduino CLI: `--build-property compiler.cpp.extra_flags=-DKEYTRAIN_COLOR_CALIBRATION=0`). Existing extra compiler flags must be retained if your build already sets them.

With the flag off, the module exposes inline no-op hooks; its implementation, serial protocol strings, render snapshot fields, and render branches are compiled out. Normal TrainPod rendering, navigation, BLE, setup and power behavior remain. Both flag values are built and tested. Keeping the flag on does not start calibration automatically: the Mac must request `cs start`.

## Isolation and lifecycle

- Module: `src/products/transit/calibration/ColorCalibration.{h,cpp}`. It deliberately lives in the transit product, so platform-only applets do not acquire a dependency on the transit renderer.
- App hooks initialize the module, route `cs` commands and service the calibration session while continuing BLE and the existing renderer.
- LCD drawing remains in the existing render worker. It bypasses palette correction. Acknowledgement is emitted only after `fillScreen` returns.
- Brightness is forced immediately to 80 on the existing 0–255 PWM scale. Prior brightness is restored on stop/timeout; normal power management then resumes.
- `cs stop` or 15 seconds without a heartbeat exits calibration and requests the normal screen again. No calibration data is written to NVS.
- Pure-black and boundary colors may produce visually identical candidates after gamut clipping/RGB565 quantization; the Mac indicates duplicate choices.

## Serial protocol (115200 baud, newline)

```text
cs hello                  -> CS HELLO 1 waveshare_c6_1_47_st7789_v1 80
cs start                  -> CS START 80
cs show 42 F2B6C6          -> CS SHOWN 42
cs ping                   -> CS PONG
cs stop                   -> CS STOP
```

Show sequence is decimal 1–999999; RGB is exactly six hex digits. Malformed commands are rejected. The protocol is backward compatible with the original Colorscape Mac app.

This collects a dataset only. Installing this feature does not apply a guessed correction to production colors. Export a calibrated map from the Mac and integrate the correction API separately when the map is ready.


## Normal-display color correction (September 28, 2026)

`KEYTRAIN_COLOR_CORRECTION=1` enables option 2, the compact RGB inverse-distance^4 blend, using 53 locked visual matches captured at brightness 80. It is independent of `KEYTRAIN_COLOR_CALIBRATION`, which controls the serial calibration tool. Set correction to 0 to compile out the map and cache.

Phone theme RGB888 values and transit route colors remain unmodified in BLE state, NVS, fingerprints and render snapshots. The renderer corrects theme roles in `pallete::setRenderTheme` and route colors in `pallete::routeColor`. A renderer-owned 64-entry FIFO cache stores RGB888 results (512 bytes plus 8 bytes metadata). Repeated theme snapshots reuse those results. RGB565 conversion happens after correction. Badge opacity blends corrected foreground/background endpoints, avoiding interpolation work for every animation step. This cache is single-threaded; do not call it from BLE handlers.

Raw `cs show` rendering deliberately bypasses correction: the Mac has already chosen the LCD command. Startup animation constants, which were already RGB565, remain unchanged. The map is used across normal brightness settings, but was matched only at 80/255; other brightness settings are not independently calibrated.

The table is a compiled snapshot in `src/products/transit/ui/theme/CompactCorrection.h`. Adding anchors on the Mac does not automatically update firmware. `firmware-calibration-snapshot.json` in the deliverable records the exact source data. Existing NVS themes retain their requested colors, so toggling correction does not require migration or resending a theme.

Host tests cover exact anchors, normal theme and route drawing conversions, source immutability, repeated snapshots, cache eviction, black, and disabled passthrough. Raw serial preview remains on its original direct RGB565 path.
