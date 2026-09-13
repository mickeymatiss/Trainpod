# MTA live arrivals: initial pass

iOS finds the two closest MTA station complexes, then selects the next nine distinct
trips per complex for the app across both directions. The screen and device show the route,
Northbound/Southbound (the GTFS stop suffix), and rounded-up minutes. These labels
are service directions, not terminal names. Fewer than nine predictions are shown
when the live feed supplies fewer; no scheduled or dummy arrivals fill the gaps.

The BLE formatter still sends only the next two trains per MTA station.

All MTA decoding, station matching, sorting, deduplication, colors and display
translation live in iOS. **The station-update contract is unchanged:** TP2 header,
P/A records, checksum footer, BLE chunking, requests and acknowledgements are
unchanged. The Arduino parser is unchanged. Its only UI change replaces the old
"Arrivals not enabled" caption and redraws correctly when an empty page gains trains.

The phone fetches all eight MTA subway feed groups concurrently, including Staten
Island Railway, so rerouted lines can still match a station's constituent stops.
Results are shared between app and BLE requests for 30 seconds. Existing 60-second
refresh behavior remains. A failed, malformed or stale feed fails the refresh;
the existing failure path preserves the previous device board and retries. This
first pass requires all feed groups to succeed. Feeds older than five minutes or
more than one minute in the future are rejected. Past predictions, canceled trips,
deleted entities, skipped stops and stops marked NO_DATA are excluded.

Transfer-complex IDs are split on semicolons (and commas for compatibility). Trips
calling at several constituent stops consume one slot. No API key, backend, or
extra Swift package is required. The protobuf reader handles only the GTFS-RT
TripUpdate fields needed here and skips unknown fields, including NYCT extensions.

Sources:
- https://www.mta.info/developers
- https://api.mta.info/
- https://gtfs.org/documentation/realtime/reference/
- https://raw.githubusercontent.com/google/transit/master/gtfs-realtime/proto/gtfs-realtime.proto
- https://data.ny.gov/resource/5f5g-n3cz.json

Validation: iOS simulator and XIAO ESP32-C6 builds; deterministic Swift checks for
parsing, filtering, deduplication, transfer IDs, freshness, next-nine app selection and the two-train device limit and
CTA color preservation; Swift-produced payload decoded by the unchanged firmware
parser; all eight real feeds decoded; live public Times Square coordinate test
returned live trains for the Times Square area.

Tests live in `tests/mta_arrivals_test.swift` and `tests/mta_live_smoke.swift`.
The corresponding active-sketch test is `tests/mta_arrivals_contract_test.cpp`.
The unit executable accepts an output payload path followed by optional saved
protobuf feed files. The smoke executable performs read-only network requests
using a fixed public Times Square coordinate, never the user's location.

The MTA screen has a persistent location menu: Current Location, Times Square, and Starr &
Knickerbocker (Brooklyn). Times
Square uses the 42 St/Broadway station-complex coordinate for both foreground and
BLE refreshes, bypasses GPS permission requests, and displays a test-location
notice. It never writes the test coordinate into CTA's shared location cache.
Changing the selection reloads nearby stations and discards obsolete results.
The Starr & Knickerbocker preset uses 40.702819, -73.925409 at the requested
Brooklyn 11237 intersection (verified with Esri World Geocoding, StreetInt match).

Install the rebuilt iOS app and select MTA, then Times Square to test from anywhere. Connect and use Send Live Data, or let
the device request its normal refresh. Double-tap switches stations. Existing
firmware already accepts the live arrival records; uploading the updated sketch
also updates the empty-state caption. No firmware upload or app installation was
performed by this implementation pass.
