# Core CTA sketch with BLE tests

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
