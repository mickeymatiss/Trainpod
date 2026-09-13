# Platform page update

Phone project: `/Users/mickeymatiss/Desktop/Trainpod/Trainpod.xcodeproj`.
Active firmware: `/Users/mickeymatiss/Documents/Arduino/sketch_cta_ble_demo`.
The older firmware directory inside the Xcode repository is not the Arduino IDE sketch.

The phone scans distance-ordered realtime candidates until two valid fetches
produce platforms. Invalid metadata, explicitly closed station names and failed
fetches do not consume a station slot. Empty arrivals with valid directions are
retained. Backfill has a 15-second selection budget; a single successful station
is still usable. This uses metadata/API availability, not a new closure-alert feed.

`LiveTransitFormatter.maximumPlatforms` is n (currently 4), with at most two
stations, two directions per station and three arrivals per page. Station order
follows distance; directions are sorted by display name with ID as a tie-breaker.
Firmware capacity is `ArrivalBoard::MaximumPlatforms` (currently 4). Increase
both capacities together when expanding, and review station/page and 2048-byte limits.

Existing TP2 text and P1 BLE request/chunk/checksum/ACK transport remain in use.
The `P` record is extended from `P\tdirection` to
`P\tdisplayDirection\tstationName`. The first station header is retained.
New firmware accepts both forms. Old firmware rejects extended records, so
upload firmware before running the updated phone app. No new BLE request is needed.
The decoder commits only a complete, checksum-valid board. Page identity remains
station name plus display direction; missing identities reset to page zero.

Host tests, from this repository:

```sh
swiftc -module-cache-path /private/tmp/trainpod-swift-cache tests/platform_formatter_test.swift Trainpod/Products/Transit/BLE/LiveTransitFormatter.swift Trainpod/Products/Transit/BLE/TransitMessage.swift -o /private/tmp/trainpod-formatter-test
/private/tmp/trainpod-formatter-test /private/tmp/trainpod-phone-fixture.txt
```

Then from the active Arduino sketch:

```sh
clang++ -std=c++17 tests/platform_pages_test.cpp -o /private/tmp/trainpod-platform-pages-test
/private/tmp/trainpod-platform-pages-test /private/tmp/trainpod-phone-fixture.txt
```

On hardware: upload the active sketch, run Trainpod from Xcode on the phone,
and request fresh data. Check `[TRANSIT] Selected station`, `[TRANSIT] Built`,
`[BLE] Sending platformCount`, `[BLE] Received platformCount` and `[UI] Platform`
logs. Cycle all returned pages and verify the station heading changes and wraps.
The existing wake-only button press remains wake-only; subsequent presses navigate.
Destination text is now regular 10pt; other headings retain regular 12pt.
