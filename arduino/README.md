# Trainpod device firmware

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
