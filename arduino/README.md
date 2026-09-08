# Trainpod device firmware

## Current hardware power lifecycle

`PowerLifecycle.h` owns one inactivity timer and the configurable thresholds:
ACTIVE for 90 seconds, DIMMED for another 30 seconds, then SCREEN_OFF_STANDBY.
PWM brightness is 30 active, 5 dimmed, and 0 in standby. Only a debounced physical
button press resets inactivity. In ACTIVE it navigates normally; in DIMMED or
standby the first press wakes only. Release and press again to navigate.

Standby keeps the CPU awake and BLE running. It pauses NEED_DATA retries and
screen drawing/pagination, retaining the board and selected platform/page in
RAM. Late pre-standby transit responses are ignored, not displayed or marked
fresh. Reconnects and BLE activity cannot wake the screen or reset inactivity.
Button wake redraws the RAM board immediately, restores brightness, then marks
the existing recovery flow as needing data. The original data timestamp is not
changed by sleeping or waking.

No explicit Light-sleep, Deep-sleep, BLE shutdown, or iOS changes are included.
The state policy is separate from hardware effects so standby can be replaced
later when the wake pin/runtime supports actual sleep. This pass has not been
built, tested, or flashed.

## Device-driven recovery

When connected and subscribed, the device sends `NEED_DATA` whenever it has no
valid board, its last valid board is at least 60 seconds old, or a transaction
failed. Attempts occur immediately, then at 1.5, 3 and 4.5 seconds; further
attempts are five seconds apart. Disconnect suspends retries without clearing
the displayed board. Reconnection uses the same need-data rule. Only a parsed,
complete board resets freshness and stops retries; notification ACKs do not.

Trainpod shares an in-memory 30-second API-result cache between the iOS view and
device requests. Cache keys include agency and ordered station IDs. A recent
location context can be reused; otherwise the app resolves location before
checking the cache. Concurrent requests for the same context share one fetch.
The cache is updated before BLE sending, so a failed send does not discard it.
BLE requests coalesce while a transfer is active, including the existing text
receiver's 250ms settling interval.

Update app and firmware together: TP2 boards now end with
`END\t<body-byte-count>\t<FNV-1a-32-hex>\n`. This verifies the complete body before
parsing without changing BLE chunking. Missing chunks, invalid boards and
unavailable responses preserve old data and leave retries active.
Firmware retries are disabled for the separate SLIP stress-test session.

This recovery pass has not been built, tested, or flashed; validation is left to
the user. The older tests and sketch notes predate the new recovery contract.

Open `sketch_cta_ble_demo/sketch_cta_ble_demo.ino` in Arduino IDE.
Board: **XIAO ESP32C6** (`esp32:esp32:XIAO_ESP32C6`).
Dependencies: **GFX Library for Arduino** and **NimBLE-Arduino**.

The current arrival screen targets the existing **320 × 172** ST7789 panel.
It shows one direction and three individual arrivals at a time, rotates pages
every five seconds, and retains cached arrivals during refreshes and failures.
The physical button switches directions and resets pagination.

Install this firmware and the accompanying Trainpod iOS changes together.
The current `TP2` payload includes per-arrival destinations and cardinal direction
labels; earlier five-field arrival payloads are no longer accepted as boards.
Older behavior descriptions in the sketch README describe the BLE integration's
history and are superseded by this arrival-screen behavior.

`ArrivalScreen` owns drawing and timing; `ArrivalPayload` decodes normalized data.
Battery state remains unknown until actual measurement is connected to
`setBatteryPercent`. No fabricated battery percentage is displayed.

The `tests` folder contains host-side checks for the screen state, payload parser,
BLE receiver, text buffer, and refresh flow. No generated build files are required.

## Departure Mono visual pass

The renderer uses Departure Mono 1.500 everywhere: 11px header/destinations/status,
22px station/route labels, and 33px ETAs (22px for four-digit values). These are integer
scales of an 11px monochrome raster, with no antialiasing. ETAs sit on the left
without units; route labels, aqua arrows and destinations have fixed starting
positions. The station heading is brighter warm white; route labels use the full
incoming route colors without dimming. The BLE circle is yellow while connecting
or waiting for notification readiness, red after 30 seconds without readiness,
and green once ready. The warning threshold is configurable in `ArrivalScreen`;
it does not stop retries or disconnect BLE. Data freshness remains separate.

Source: https://github.com/rektdeckard/departure-mono/releases/tag/v1.500
The SIL OFL is included in `sketch_cta_ble_demo/DEPARTURE-MONO-LICENSE.txt`.
To regenerate the embedded ASCII/arrow subset, run `tools/generate_departure_font.py`
with Pillow and the release's `DepartureMono-Regular.otf`, saving stdout as
`sketch_cta_ble_demo/DepartureMono11.h`. Source OTF SHA-256:
`4d53f663155cf8bf7ffc8e688776e719625f7bbb80a8d90073438b249261a2e0`.
