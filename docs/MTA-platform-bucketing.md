# MTA service-direction platforms

All normalization happens in iOS. The app selects the next nine distinct trips per
station, sorts them by arrival time, and groups them by service direction across
routes. These are logical direction buckets, not claims about physical track numbers.

Direction priority:
1. NYCT TripDescriptor extension field 1001, direction field 3: NORTH=1, EAST=2,
   SOUTH=3, WEST=4. Explicit direction takes priority over the stop suffix.
2. A recognized N/S/E/W child-stop suffix, matched to a known station stop ID.
3. Direction TBD. An ambiguous train is not assigned a guessed compass direction.

Official definitions: https://www.mta.info/developers links to the NYCT protobuf
at https://raw.githubusercontent.com/OneBusAway/onebusaway-gtfs-realtime-api/master/src/main/proto/com/google/transit/realtime/gtfs-realtime-NYCT.proto.
MTA uses service directions; physical east/west travel does not necessarily imply
an Eastbound/Westbound feed label. No route-wide geographic or destination guesses
are applied. Other unrecognized direction listings remain separate as Direction TBD.

The app considers all matching predictions when discovering buckets before taking
the next nine trains. A lone known direction retains its opposite as an empty bucket
for navigation. Empty buckets say that none of the selected nine trains are in that
direction; no live data produces Direction TBD instead of invented direction labels.

Existing DirectionArrivals and TP2 P/A records, field limits, checksums and BLE
transport remain unchanged. Current device limits (nine arrivals per platform,
30-minute window, two platforms per station/four total) are preserved. An unusual
station with more than two direction buckets remains fully visible in the app;
the payload formatter rejects it with a capacity error instead of silently dropping
directions or merging incompatible groups. No firmware source changes are needed.

Validation covers explicit east/west, metadata precedence, suffix fallback, unknown
and unsuffixed stops, grouping across routes, chronological ordering, deduplication,
empty buckets, nine-arrival selection, and overflow rejection. The existing device
decoder accepts the Swift-produced payload, and single/double-tap state checks
confirm platform/station navigation. Live Times Square feeds and the iOS build pass.
