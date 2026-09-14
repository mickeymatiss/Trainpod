# Current selected firmware — September 14, 2026

The current changelog is in the repository's `CHANGELOG.md`. Current serial
appearance controls and defaults are in [docs/DISPLAY-EFFECTS.md](docs/DISPLAY-EFFECTS.md),
with [night brightness](docs/NIGHT-BRIGHTNESS.md) and
[serial logging](docs/SERIAL-LOGGING.md) documented separately.

The selected version includes persistent device identity, the uniform instrument
UI, typography, staggered transitions, button feedback, bloom, lip and depth.
Experimental scan, lens and bevel variation code/controls are removed.
The app is KeyTrain Connect, with matching identity and T2 local-time support.
Firmware updates must preserve NVS to retain identity and saved themes.

No build, test or flash was performed for this selection/commit pass.

## Historical implementation notes

The entries below describe earlier iterations. Their defaults, UI labels, command
names and validation statements may predate the current version. Prefer the
current documents linked above when operating the device.

## Product file organization

Transit product code is now grouped into `app`, `data`, `input`, `ble`, and `ui`.
The UI folder contains `animation`, `fonts`, and `theme` subfolders. See
[src/products/transit/README.md](src/products/transit/README.md) for responsibilities.
The Arduino `.ino` entry point and visible root `pallete.h` tab remain in place;
Arduino discovers the moved source files recursively. Platform files are unchanged.

## Twelve full UI themes

The iOS Nearby picker now offers the 12 named presets from the supplied catalog
in a two-row horizontal grid. Tap a card for a local preview; **Push to Device**
is explicit. The selected Book / Tan preview on app launch does not change the
device. No theme is pushed automatically on launch or reconnect.

Theme roles, in wire order: background, primaryText, detail, secondaryText,
arrivalBadge, arrivalBadgeText. Divider uses detail. Route squares use incoming
transit RGB values and are never themeable. Removed diamonds remain removed;
the centered distance, ETA fades, and two-second BLE hold are preserved.

BLE version 1 uses six atomic 20-byte packets: `UT:1234ABCD:0:RRGGBB` through
`UT:1234ABCD:5:RRGGBB`, followed by `UT:1234ABCD:C`. The token identifies one
push. Field 0 starts a new transaction; all six fields must arrive within ten
seconds and the same connection before commit. The bridge serializes the whole
sequence against transit messages. Partial or malformed updates cannot change
runtime or storage. No packet needs an ATT payload greater than 20 bytes.

Success is `TA:1234ABCD:HHHHHHHH`, where H is uppercase FNV-1a-32 of the stored
18 RGB bytes (R, G, B for each role in wire order). The app verifies this against
the selected snapshot before marking it confirmed. Errors with the same prefix
and token are E1 invalid/incomplete, E2 storage failure, E3 busy. A lost ACK can
mean the theme was saved; an explicit retry is safe.

Preferences `ui/theme` is one versioned 28-byte blob committed before the active
palette changes. Valid stored themes win on boot. If no theme key exists, old
`ui/color` selections remain supported over the existing factory palette.
A malformed theme falls back to the factory palette. Startup does not persist
a default. The legacy UC background command updates only the background of the
active palette and persists the resulting full theme.

The factory palette remains available for devices without a preference; it is
not replaced by the app's initial selection. Successful theme changes reuse
the normal buffered theme redraw. No train data, page, or platform is reset.

Not built, tested, or flashed, per the user's request.

---

## Two-second hold: 60-second BLE window

Hold GPIO9 for two seconds to start a 60-second BLE availability window. A
later hold restarts the window. Release after activation; continuously holding
fires only once. A hold works from active, dimmed, or screen-off state and does
not navigate. Short single/double taps are recognized on release.

During this window, completion of a train refresh, the normal session timeout,
and screen standby do not close BLE. A phone disconnect tears down normally
and restarts advertising for the remaining window. When the timer expires,
normal lifecycle rules resume, including the existing minimum connection hold
and any active diagnostic export. The separate Serial permissive debug mode
still takes precedence if explicitly enabled. The window is not persisted.
Serial prints activation and expiry. No builds, tests, or upload were run.

# Current Arduino IDE sketch

Open `sketch_cta_ble_demo.ino` in this folder. Arduino IDE compiles the `.cpp`
files under `src/` automatically. Product code lives in `src/products/transit`.

The root `pallete.h` tab exposes the color settings in Arduino IDE.
The `pallete` class now owns display colors and stores an optional RGB888
background in Preferences (`ui/color`). This sketch retains its existing
`#D6CCBB` factory background. It loads before the first render; absence does
not write a preference. A saved selection always wins on subsequent boots.

The iOS Nearby screen offers background swatches and **Push to Device**.
The existing characteristic accepts the atomic 19-byte compact SET_UI_COLOR
command `UC:1234ABCD:#RRGGBB`. The eight hex digits identify the request.
After persistence and runtime application, it replies `UA:1234ABCD:#RRGGBB`.
Errors use the same token and `E1` (invalid_color), `E2` (storage_failure), or
`E3` (busy). The app waits for this ACK rather than the BLE write response.
No automatic color push occurs on launch or reconnection. A lost ACK leaves
confirmation uncertain; explicitly retrying the selected color is safe.

Configuration writes bypass train payload assembly. NVS writes and redraws run
on the main Arduino loop. The existing navigation canvas is reused to compose
a color update without visibly clearing the panel. Page/platform and cached
train data remain intact. Bottom station diamonds have been removed.

The existing on-demand BLE lifecycle is preserved: push while connected;
BLE is off in standby, so a sleeping device must wake/connect before a push.
Stored color survives independently while BLE is off, asleep, or power-cycled.

No builds, tests, or upload were run for this change, as requested.

---

# Core CTA sketch with BLE tests

## Station rhombuses

The centered footer now shows one 13x13px equal-sided diamond per distinct
station, in received station order, with 24px center spacing for two stations.
The active station has a muted slate outline and matching directional half-fill:
top for North, right for East, bottom for South, left for West, and diagonally
oriented halves for NE/SE/SW/NW. The other half stays the screen
background color, with no internal dividing line. Inactive stations are empty
diamonds with quiet outlines. Non-cardinal labels retain the active outline
without inventing a directional selection. No text is drawn inside the indicators.

Outline and half-fill colors crossfade together over 175ms as navigation changes.
Retargeting begins from the currently interpolated colors. This fade is separate
from the train-content dip and updates only the centered indicator strip.

## Platform navigation dip

Navigation uses five non-blocking steps at 35ms intervals (175ms nominal):
70%, 35%, swap at 35%, 70%, 100%. Same-station switches leave the station
heading untouched; cross-station switches include it. Direction, route squares,
route labels, destinations, ETA capsules/numbers and distance share the dip.
Selection indicators change once at the swap. Battery, connection status and
the static divider are never transferred as part of the transition.

A lazily allocated 320x172 RGB565 canvas (110,080 bytes) composes each frame
in RAM. Only affected rectangles are copied to the display; clearing the canvas
does not clear the TFT. Allocation failure leaves the current page intact and
logs a message. Incoming boards are deferred to the swap/recovery boundary;
new button input replaces the requested destination without queuing transitions.
Ordinary ETA updates keep their separate localized fade.

ETA cream intensity is reduced 10%, and route squares/labels are shifted 4px
right. The tan background remains unchanged.

Tests: `tests/platform_dip_test.cpp` verifies timing and swap phases, and
`tests/eta_render_test.cpp` verifies actual renderer transfer boundaries for
same-station, cross-station and retargeted navigation. Check physical timing
and available heap after upload; nominal timing assumes rendering fits each step.

## ETA fades

The screen retains tan (#D6CCBB) and black labels, with warm cream ETA
numbers (#F4E6CC) on near-black navy capsules (#080E17). ETAs use FreeSans
Bold Oblique at native 18/12/9pt, choosing the largest that fits the fixed field.

Numeric changes fade to the capsule background over 125ms, swap at zero
visibility, and fade in over 125ms. Each half has five updates at roughly 25ms
intervals. All changed slots use the same update timestamp. Unchanged targets
never repaint. New targets replace pending values, or redirect a fade-in back
toward black before showing the latest value. The loop remains non-blocking.

Each frame clears only the previous glyph bounds inside its fixed ETA capsule
and draws the current glyph at an interpolated RGB565 color. Ordinary data
updates compare cells, and status updates repaint only the footer. Station or
platform changes render immediately, without a fade. New/removed rows are also
immediate. The fixed number field and other font sizes are unchanged.

Host checks:

```sh
clang++ -std=c++17 tests/eta_fade_test.cpp -o /private/tmp/trainpod-fade-test
/private/tmp/trainpod-fade-test
clang++ -std=c++17 -Itests/render_stubs tests/eta_render_test.cpp -o /private/tmp/trainpod-eta-render-test
/private/tmp/trainpod-eta-render-test
```

The renderer test compiles the production renderer with a recording display
and actual font metrics to verify drawing stays within the changed ETA fields.
Physical smoothness still needs checking after firmware upload.

## Button navigation

Single tap cycles platforms within the displayed station. Double tap (two
debounced presses within `ButtonTap::DoubleTapMs`, currently 300ms) switches to
the next station, retaining the same direction when available, otherwise using
its first platform. Singles wait for the double-tap window to expire; doubles
do not also fire a single. Each list wraps using the received pages only.
The existing wake-only press remains wake-only, and wake-test mode suppresses
navigation. This behavior requires only a firmware upload, no phone update.

Host checks: `tests/button_navigation_test.cpp` and `tests/platform_pages_test.cpp`.

## Current source organization

The Arduino entry point delegates to `src/products/transit/app/TransitApp.cpp`.
Reusable BLE, transport, power, metrics, and board hardware live under
`src/platform/`; transit protocol, freshness, parsing, UI, and fonts live under
`src/products/transit/`. Arduino recursively compiles `src/`. Older filenames
below refer to those relocated files; `TransitTextBuffer` is now `IdleTextBuffer`.
This extraction preserves runtime behavior, including CPU-awake standby.

## On-demand BLE lifecycle

`BleSession` now owns an explicit `Off -> Starting -> Advertising -> Connected ->
Transferring -> Completing -> Stopping` lifecycle. BLE is initialized only when
the existing freshness flow needs data. An unanswered session shuts down after
15 seconds. A validated board is committed before a non-blocking 350 ms grace
period, disconnect, and full `NimBLEDevice::deinit(true)` shutdown. Runtime
shutdown deletes only NimBLE objects; it does not erase bonds, keys, identity,
or peer data.

Every accepted connection also has a non-blocking five-second minimum lifetime,
measured from that connection's callback. Completion or failure may mark the
session eligible to close earlier, but local disconnect and stack shutdown wait
until both that decision and the five-second hold are satisfied. A later
connection starts a new five-second window.

Malformed/oversized data, parse failure, unexpected disconnect, session timeout,
and standby preserve the last valid board and return BLE to `Off`. The existing
wire format, chunking, framed ACKs, payload parser, 60-second freshness policy,
and display remain unchanged. Failed sessions observe the existing 5-second
slow-retry interval before the application may open another transport window.
Lifecycle logs use the `[BLE]` prefix. This change has not been compiled, flashed,
or device-tested, at the user's request.

## Quiet Wayfinding screen

Palette correction: the current screen uses warm tan paper `#DFCCA7` for the background,
black `#000000` for primary/secondary text and utility indicators, and a subtle
`#B39F7D` divider. Route colors and layout are unchanged. This supersedes the
dark-background and off-white/gray text descriptions below.

Renderer-only styling on the existing **320x172** panel (the supplied concept
uses 320x176; no display-driver dimensions or pin configuration were changed).
Background `#111312`, primary `#F2EFE7`, secondary `#8D918A`, divider `#343733`;
Green/Pink route labels use `#4F8B5B`/`#D85C88`. Other routes retain their incoming
identity colors. RGB colors are converted to the panel's RGB565 representation.
Departure Mono, integer scaling, truncation, three-row spacing, arrival ordering,
platform switching and paging are retained. ETA and route labels are left-aligned
in adjacent fixed columns; destinations are right-aligned to the screen padding.
Cyan accents and the persistent clock/bolt are removed.

Healthy BLE/fresh data show no left-footer status. Reconnecting shows a muted
dot; the existing 30-second connection warning shows `BLE!`. Battery is hidden
when unknown or above 30%, muted at 15–30%, and off-white below 15% (there is still
no battery ADC configured). Existing arrivals stay visible during refresh; no
new loading indicator or refresh behavior is introduced. Age appears as `2m old`
from the existing two-minute display threshold, escalating to off-white with `!`
at ten minutes. These visual age thresholds are constants in `ArrivalScreen.h`;
they do not invalidate or discard data. Contextual warnings can coexist without
adding permanent icons. A tiny gray diamond remains at bottom-right, with the
existing page count/selection represented when multiple pages are available.

This visual change is not built, tested, or flashed; physical readability is for
the user to check on the device.

## Persistent device metrics

Serial Monitor: **115200 baud**, newline (CRLF also works).

- `metrics` prints all current aggregate fields, including unsaved RAM changes.
- `metrics flush` clears the aggregate counters in RAM and immediately saves the
  cleared record to NVS. This is destructive and has no undo. A failed NVS save
  is reported explicitly. New events continue counting; in-flight pre-reset
  operations are excluded, and startup counting resumes on the next boot.

The Serial command `metrics flush` means **reset**, as requested; the internal
`MetricsStore::flush()` method still means **save**, not reset. Neither command
changes the train board, BLE connection, or BLE test statistics.

`MetricsStore::shared()` owns a version-1, fixed-size 72-byte aggregate in
Preferences/NVS namespace `device_metrics`, key `aggregate`. No event log, BLE
export, duplicate refresh counters, or optional runtime counter is added.
`get()` returns a thread-safe copy suitable for future serialization.

- Boot count increments once in setup. Panic, watchdog, brownout, efuse error,
  power glitch and CPU lockup resets increment the unexpected-reset counter;
  ordinary power-on/software restart/deep-sleep wake do not.
- All accepted GPIO9 presses count, including consumed wake presses.
- Startup latency uses ESP's monotonic uptime from startup (not time after LCD
  initialization). Only the first valid board accepted with a working display
  records success and one histogram bucket. Existing errors or entering standby
  without data record failure, at most once per boot. Later recovery cannot
  change that boot's outcome. A persisted pending-startup flag resolves an
  interrupted startup as failure on the following boot.
- BLE attempts count incoming connections actually exposed by NimBLE. Accepted
  links count success; locally rejected connections count failure. Normal
  disconnects are NOT connection failures. As a peripheral, this firmware cannot
  observe central-side scans or connections that fail before its callback;
  those timeouts require app-side metrics, not invented device counts.
- A fetch episode starts with the first NEED_DATA and includes all notification
  retries/chunks. Valid data ends it. The first enqueue failure, malformed/error
  response, overflow, disconnect, or standby interruption records one failure.
  Failed episodes remain latched through retries until valid data, disconnect,
  or standby ends the episode; late recovery is not a second success. Unsolicited
  valid app pushes can satisfy startup but do not invent device fetch attempts.
  There is no new fetch timeout; unanswered requests close at existing lifecycle
  boundaries. Interrupted in-flight counts may remain unresolved after power loss.

Events only update RAM under a short critical section. NVS writes run outside
BLE callbacks/mutexes, on the Arduino task: once at boot, once after the startup
outcome, on screen-off standby entry, and every five minutes if dirty (including
while in standby). Failed saves retain dirty RAM and retry at the periodic
interval. Unknown schema or unreadable storage is preserved and metrics fall
back to RAM for that boot. Counters saturate instead of wrapping.

Sudden power loss can lose events since the last successful checkpoint (normally
up to five minutes); this is deliberate to limit flash wear. A power cut before
the startup-outcome checkpoint may classify that startup as interrupted. No
intentional shutdown/deep-sleep path currently exists: any future such path must
call `MetricsStore::shared().flush()` before sleeping/restarting. Current standby
already flushes. Metrics never erase NVS or alter BLE retry/rendering policy.

This metrics change has not been compiled, tested, or flashed.

## Power lifecycle on the current GPIO9 hardware

`PowerLifecycle.h`: ACTIVE (30s) -> DIMMED (30s) -> SCREEN_OFF_STANDBY.
Backlight changes ease over 1000 ms using the platform `BacklightFade` helper,
including startup, wake, dimming, and fade to off. Fades run in the normal loop
and can reverse smoothly on a button press. Brightness targets are unchanged.
Brightness/debounce/timeouts are configured in `PowerConfig`. Only physical
button presses reset inactivity. A press in DIMMED or standby wakes only; the
next press navigates. Standby keeps the CPU awake, shuts BLE down, pauses NEED_DATA and rendering,
and preserves the selected platform/page and train board. Wake redraws RAM data
immediately before requesting fresh data via the existing recovery flow.
No actual Light-sleep/Deep-sleep calls or iOS changes are made. Not built/tested.

## Current recovery behavior

The tracker opens a BLE session whenever it lacks fresh valid data, then sends
`NEED_DATA` after the phone connects and subscribes. In-session request retry
timing is immediate, 1.5s, 3s, 4.5s, then every 5s.
Only a complete validated TP2 board resets the 60-second data age and stops
retries. Disconnect aborts the transport session while preserving the board;
the application can start a fresh session after its retry interval. No loading
screen is added.

Install the accompanying Trainpod app update: it shares a 30-second API cache
between the iOS screen and BLE requests, coalesces duplicate fetches/sends, and
adds `END\t<body-byte-count>\t<FNV-1a-32-hex>\n` to TP2 boards. The receiver
rejects incomplete or damaged bodies before marking data fresh. BLE chunking,
MTU, discovery and the screen layout are unchanged. Unavailable/error replies
keep old arrivals visible and leave retries active.

This pass has not been built or tested, at the user's request. The notes and
test fixtures below describe earlier behavior and predate this recovery pass.

## Automatic refresh (current behavior)

Connection now requests transit data automatically when none exists or its age
is at least 60 seconds. A connected device also refreshes at the 60-second age
boundary. Only valid parsed transit data resets that clock. Button wake uses this
same connection freshness check, so waking with fresh data sends no request.
One shared in-flight guard prevents duplicates. The 30-second timeout retains
old trains and shows REFRESH FAILED; retries wait for reconnect. This supersedes
the earlier button-only request behavior described below.

This integrates the test fork into the original display sketch. The original
transit parser, display layout, animation, pin assignments, service UUID and
device name are preserved. BLE callbacks assemble bytes; the Arduino loop parses
transit text and renders it. No iOS changes are required.

## Use

Background dummy relay: connect from Nearby in the updated iPhone app, leave the
reconnect-only test disarmed, send ble off, lock for 30 seconds, then press GPIO 9.
The button starts loading; after reconnect and notification subscription the
device sends REFRESH_REQUEST. iOS responds with the existing dummy transit text,
and the normal parser/renderer displays it. Check the [E2E] logs and Nearby's
persisted background request counter. A 30-second failure shows REFRESH FAILED.
Connecting without a button request no longer auto-sends dummy data. The BLE
Test screen connects on demand; keep it disconnected during the relay test.

Upload sketch_cta_ble_demo.ino to the ESP32-C6. Serial: 115200 baud, newline.

- Transit screen: connect and send the dummy or actual station payload. The
  existing station/direction/line display renders it. GPIO 9 switches directions.
- BLE Test screen: disconnect the transit connection first, connect from BLE
  Test, and run the existing presets. SLIP assembly, CRC checks, ACK notifications,
  sequence diagnostics and summaries are available. Synthetic test bytes do not
  replace the station display.
- Serial commands: stats, reset, verbose on/off, raw on/off, ble off.
- Wake experiment: arm Background Reconnect in iOS, send ble off, background and
  lock for 30 seconds, then press GPIO 9. Check the persisted iOS background flag,
  counter and timestamp. No automatic payload is sent at reconnect.

The first nonempty write selects the wire format for that connection: a leading
SLIP delimiter selects test frames; otherwise it selects legacy transit text.
Disconnect and reconnect when switching formats/screens. This preserves the
existing two iOS send paths without confusing test bytes with display data.

Legacy transit text is capped at 2048 bytes and assembled until 250 ms without a
write. Allow that idle gap between sends. Because the existing sender has no
length or delimiter, long inter-chunk pauses or back-to-back messages cannot be
distinguished perfectly; this compatibility path is not a new reliable framing
protocol. Oversized/NUL-containing text is rejected. Framed tests retain their
32768-byte limit, explicit boundaries, CRC and ACKs. A CRC OK ACK confirms test
frame receipt, not successful transit parsing/rendering.

ble off ignores payload writes and reserves GPIO 9 for waking until reconnection.
The core firmware resumes normal reception after reconnecting. iOS reconnects
automatically without suppressing writes by default. Explicitly arming the iOS
reconnect-only test still blocks sends; disarm and reconnect to resume traffic.
reset resets receive statistics, not wake mode. No deep sleep or power
optimization is added.

## Checks

ESP32-C6 compilation and host receiver/buffer regression tests passed. Physical
display, transfer and locked-phone reconnect checks on this combined firmware
still need to be run after upload.

Host tests (from this sketch directory):

    clang++ -std=c++17 BLETestReceiver.cpp tests/receiver_test.cpp -o /tmp/core-receiver-test
    /tmp/core-receiver-test
    clang++ -std=c++17 tests/transit_buffer_test.cpp -o /tmp/transit-buffer-test
    /tmp/transit-buffer-test
