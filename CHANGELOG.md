# Changelog

## Firmware reliability — working changes

- Move TFT initialization, setup screens and drawing into one independent renderer task.
- Keep authoritative transit state, navigation and timers on the application loop; publish latest-state snapshots without waiting for TFT.
- Use one bounded update pipeline for startup, refresh and retry with independent update/render timing and stall diagnostics.
- Pin CPU frequency while rendering is enabled to avoid SPI/APB lock coupling.
- Add optional serial render fault controls; source review only, no builds/tests/flashing.

See `docs/FIRMWARE-RELIABILITY.md` for ownership, audit findings and driver limitations.

## Device registration V1 — working changes

- Add independent firmware provisioning state and a physical-button setup window.
- Keep unprovisioned BLE advertising enabled from boot, independently of button
  readiness, inactivity, display and normal session timers; re-arm after disconnect.
- Add setup status/command/result characteristics beside the unchanged identity
  and transit characteristics. Persist one complete binding atomically in NVS.
- Gate iOS startup with a single setup card. Store installation identity and
  pending/bound credentials atomically in Keychain before claiming.
- Recover interrupted claims using the same pending credentials and permanent ID;
  reject subsequent initial claims and retain ownership on failed attempts.
- Verify registered device identity before enabling normal transit/clock traffic.
- Provide explicit local reset APIs that preserve permanent firmware identity.
- Source review only; no builds, tests or flashing, per user preference.

See `docs/SETUP-BINDING.md` for protocol, lifecycle and manual acceptance details.

## Selected for integration — 2026-09-14

Selection: retain B01–B07 and A01–A16 plus A18. Exclude A17.
This records the selected source changes on `ui-tests`; it does not assert a
main-branch merge, release, successful build or hardware validation.

### Device identity and transit behavior

- A01: Generate a persistent `TP-` identity from 128 ESP32 hardware-random bits
  only when the NVS `trainpod/deviceId` key is absent. Load existing IDs unchanged.
  Expose a dedicated read-only characteristic
  `7A1C0003-8F4A-4D2B-9A57-1C2D3E4F5001`; iOS reads, logs and caches it per connection.
  No binding, ownership or identity-based app connection policy. Storage errors
  preserve records and prevent firmware advertising an unpersisted identity.
  Updates must preserve NVS.
- A02: Keep the first three upcoming trains even beyond 30 minutes; later trains
  retain the 30-minute cutoff and the nine-arrivals-per-platform cap.
- A03: Reset test-location selection to current location at app startup.
- A04: Add quiet Info and detailed Debug serial modes while retaining diagnostic
  history and warnings; log screen darkness when the backlight fade completes.
- A05: Add night brightness from 22:00 through 06:59 local time. Active PWM is
  80 by day, capped at 50 at night or with unknown time. Pair the iOS T2 UTC-offset
  clock packet with the firmware parser; firmware still accepts T1 for diagnostics.
- A06: Switch distance display to miles at 1,000 feet; shorter distances use
  feet rounded to hundreds.
- A07: Show the first arrival page for eight seconds and later pages for six.

### iOS presentation

- A08: Add Main/Dev navigation with city selection, connection controls, request
  status and customization access; retain developer transit/BLE/diagnostic tools.
- A09: Add a simplified customization screen with previews, six leading palettes,
  color-role editing, optional live updates and explicit Save to TrainPod.
- A10: Rename the app/project/shared scheme to KeyTrain Connect and install its
  new icon. Bundle ID changes from `mmmatiss.Trainpod` to
  `mmmatiss.KeyTrainConnect`, making it a separate iOS application identity.
- A11: Match app and firmware factory palettes: pale pink background, purple
  primary text, red detail, near-black secondary text, black gauges and peach
  gauge text. Existing valid saved device themes take precedence.

### Device appearance and interaction

- A12: Update station/route/destination typography and uniformly fit bold-oblique
  ETA numerals. Include the Barlow font assets and generator size options.
- A13: Keep the instrument shell visible for empty rows, with neutral route
  placeholders and blank unknown distance; update changed content independently.
  Same-view refreshes fade changed ETAs, including newly appearing values.
- A14: Add staggered selective transitions for station/platform and page changes:
  default 200 ms out, 75 ms gap, 200 ms in, 75 ms stagger (775 ms total).
  Preserve unchanged fields, uniform rims, and render-speed/caching support.
- A15: Add a push-in button tab with current defaults 50×17 px, depth 10,
  radius 7, press 350 ms, release 120 ms. Held buttons/simulations keep the screen
  awake; held-at-boot presses are recognized. Retain normal tap and BLE actions.
- A16: Retain ETA bloom, uniform bezels, screen lip and numeral depth. Bezels use
  thickness 2, brightness 50%, contrast 40%; bloom uses radius 1 and intensity 18%.
- A18: Retain serial tuning for selected effects, transitions, night brightness
  and logging. `reset` restores visual defaults; `receiver reset` resets transport
  statistics. Update current documentation and mark older README notes historical.

### Excluded

- A17: Remove scan-band rendering, lens distortion and deterministic bevel
  variation, including their state, tuning commands and dedicated variation docs.
  Retained demo presets only adjust supported effects and cannot enable them.

### Existing branch foundation retained (B01–B07)

Keep the five preceding commits beyond the original local main (`6c2540d`):
`b49287e`, `967d8c2`, `5e2cefe`, `09b2a6a`, `579c742`.
They include product/platform organization, BLE delivery/background recovery,
Arduino transit/power runtime, CTA/MTA data and caching, diagnostics/metrics,
stored theme functionality, and the earlier display styling.

### Validation

Per user instruction, no builds, tests or flashing for this selection pass.
Source and Git changes were inspected to prepare the commit. Personal Xcode
workspace state is excluded. Hardware acceptance remains with the user.
