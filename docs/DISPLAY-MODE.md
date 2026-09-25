# TrainPod display mode

Choose **Standard** or **Compact** in iOS **Customize → Display mode**, then **Save display mode to TrainPod** while connected. The local theme preview follows the selection immediately; the nearby-arrivals view follows the device-confirmed mode (cached per permanent device ID when offline).

- Standard retains three arrivals per page and destinations.
- Compact shows up to six arrivals in two columns and three rows: 1–2, 3–4, 5–6. Each cell retains the ETA gauge, route color window, and abbreviated route name; destinations are hidden.
- Both modes share the existing renderer, gauge effects, theme, and field animations. Incoming numbers, color windows, line names, and destinations (when shown) fade together over 0–300 ms. Changed distance values share that same reveal window; unchanged distance values and units remain steady. The header keeps its existing transition timing.
- The existing sorted transit feed, nine-arrival capacity, time window, and page dwell times remain in use. Compact advances to the remaining arrivals after its first six. Empty cells remain empty.

## Persistence and synchronization

`DisplayMode` loads `ui/viewMode` from ESP32 Preferences at boot (`0` standard, `1` compact; missing defaults to standard). Reads and repeated saves of the active value do not write NVS. Changes are applied only after a successful NVS commit. Theme saves and normal firmware updates do not replace this key; full flash/NVS erasure removes it.

iOS reads the current mode after a verified BLE connection is ready, using the existing serialized control transport. Reconnects read device state, never push a cached preference automatically. A matching application acknowledgement confirms persistence before the app reports success. Failed or interrupted saves can be reconciled with **Read mode from TrainPod**.

## BLE control protocol

The existing transit/control characteristic carries one atomic 13-byte request:

- `VM:1234ABCD:?` — read current mode
- `VM:1234ABCD:0` — save Standard
- `VM:1234ABCD:1` — save Compact

Notification response: `VA:1234ABCD:0` or `VA:1234ABCD:1`. Errors use `E1` invalid request, `E2` persistence failure, or `E3` queue full. The token correlates each response to its request; queued work belongs to its originating BLE session. BLE callbacks only queue work; persistence and rendering run on the application loop. No connection-lifecycle changes are made.

Implementation has been source-reviewed only. Build, device testing, and deployment are left to the user.
