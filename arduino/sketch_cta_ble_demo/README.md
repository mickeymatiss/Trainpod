# Core CTA sketch with BLE tests

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
platform switching and paging are retained. ETA is now right-aligned in its
existing numeric column. Cyan accents and the persistent clock/bolt are removed.

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

`PowerLifecycle.h`: ACTIVE (90s) -> DIMMED (30s) -> SCREEN_OFF_STANDBY.
Brightness/debounce/timeouts are configured in `PowerConfig`. Only physical
button presses reset inactivity. A press in DIMMED or standby wakes only; the
next press navigates. Standby keeps CPU/BLE awake, pauses NEED_DATA and rendering,
and preserves the selected platform/page and train board. Wake redraws RAM data
immediately before requesting fresh data via the existing recovery flow.
No actual Light-sleep/Deep-sleep calls or iOS changes are made. Not built/tested.

## Current recovery behavior

The tracker now sends `NEED_DATA` whenever connected/subscribed and lacking
fresh valid data. Retry timing is immediate, 1.5s, 3s, 4.5s, then every 5s.
Only a complete validated TP2 board resets the 60-second data age and stops
retries. Disconnect suspends attempts while preserving the board; reconnect
uses the same generic rule. No loading screen or forced disconnect is added.

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
